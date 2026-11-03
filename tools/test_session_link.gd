extends SceneTree

## Task 7 修复轮 1：**双进程真实 RPC 测试**（父进程）。
##
## ------------------------------------------------------------------
## 【为什么必须有这个测试】
## ------------------------------------------------------------------
## headless 单进程里两个 peer 不能共用同一个 `MultiplayerAPI`
## → tools/test_session.gd 里的「投递层」是**测试替身**：它只验证
##   「收到的数据被正确应用」，**不覆盖真实 RPC 的序列化与传输**。
## 上一轮就是这么漏掉了三个必然发作的真实链路缺陷：
##   C1 清单载荷不是纯数据 → 客户端收到的是 EncodedObjectAsID 占位符（字段全读不出来）
##   C2 名单广播在原生 peer 回调里同步发 → 被引擎拒收（客户端永远拿不到名单）
##   C3 房主被自己的连接超时拆台 → 房间 8 秒后自己消失
## → 所以真实链路必须有自动化覆盖，不能只靠 Task 13 手动验收。
##
## 【做法】
## 用 OS.execute 拉起**两个真的 Godot 子进程**（一个 host、一个 client），
## 走真实的 rpc_id 投递 + 真实的跨进程序列化。
##   * 子脚本：res://tools/session_link_child.gd（**故意不叫 test_*.gd**，
##     否则会被统一入口当成独立测试单独跑）
##   * 子进程用 OS.get_cmdline_user_args() 读 `--` 之后的
##     mode / base / span / 交接文件路径（修复轮 3 的新契约）
##   * 子进程有自己的兜底退出（--quit-after + 显式 quit(0)）
##   * 子进程的输出被**捕获**（不是继承），父进程的 stdout/stderr 保持干净
##
## 【房主必须比客户端活得久】（修复轮 1 的关键实测）
## 客户端「连上后 ~9 秒掉线」的真正原因不是 ENet 空闲超时，而是**房主子进程
## 先退出了**：房主一退出，UDP 端口消失，客户端下一次收发收到 ICMP 端口不可达
## → 套接字被重置 → ENet 判连接断开。
## → 子进程里把**回报时刻**和**退出时刻**分开（见 tools/session_link_child.gd）：
##   房主 10 秒回报 / 14 秒退出，客户端 10.5 秒回报并退出。
##   两个进程都在「链路还活着」的时候回报，父进程才能断言两端状态。
##
## 【端口：运行时动态分配】（修复轮 3 / F3）
## 固定端口 = 隐含「全局只有我一个人跑」的假设，而 SDD 流程里
## 「控制器跑统一入口」与「复审子代理跑测试」是**必然并发**的
## → 固定端口必然被抢 → 产生**假失败**（实测：端口 27040 被占 →
## 12 条断言连锁失败、退出码 1；端口一释放立刻恢复全绿）。
## → 端口从 res://tools/port_alloc.gd 的候选池（27100 起、跨 200 个）里取，
##   并且**由真实的服务端 socket 裁决**（绑定成功才算可用，失败就换下一个）。
##
## 【★ 交接文件（handoff file）替代魔法延迟】
## 房主在**子进程**里，父进程必须在**启动客户端之前**知道房主实际占的是哪个端口。
## 原来的做法是 `OS.delay_msec(1500)` —— 既慢又不可靠。
## → 房主**绑定成功之后**立刻把端口号写进交接文件；父进程**轮询**这个文件。
##   「文件存在」⟺「端口已被占住」→ 客户端**一定**能连上房主。
##
## 【断言的 4 件事】
##   ① 客户端收到了房主名单 → 两边 peer_count 一致且 == 2
##   ② 客户端拿到的是**真实数据**（能读出 id/title/category/target_tag，
##      且不是 EncodedObjectAsID 占位符）
##   ③ 房主**超过 8 秒之后仍然健在**（直接锁死 C3）
##   ④ 客户端收到的**只有自己那一份**清单（不泄漏别人的）

const PortAlloc := preload("res://tools/port_alloc.gd")
const CHILD_SCRIPT := "res://tools/session_link_child.gd"
## 子进程的兜底退出帧数。
## **注意**：headless 实测 ~146 fps（不是 60），所以「N 帧」远小于「N/60 秒」：
## 900 帧只有 ~6 秒，会在子进程活满 10.5 秒**之前**把它掐掉（子进程就来不及回报）。
## 这里给一个足够大的兜底值（20000 帧 ≈ 2.3 分钟），真正的退出靠子进程自己的 quit(0)。
const CHILD_QUIT_AFTER := "20000"
## Session 的连接超时窗口（秒）。房主/客户端都必须活过它。
const CONNECT_TIMEOUT_SEC := 8
## 房主子进程比客户端多活多少毫秒（房主必须 outlive 客户端，见文件头）。
const HOST_LIFE_MS := 14000
const CLIENT_LIFE_MS := 10500
## 房主子进程最多试多少个候选端口（父进程给一个**落在候选池内**的线性窗口）。
const HOST_CANDIDATES := 8
## 交接文件轮询：间隔（毫秒）与上限（毫秒）。
const HANDOFF_POLL_MS := 25
const HANDOFF_TIMEOUT_MS := 15000

var _fails := 0
var _total := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")

	# --- 交接文件：名字必须**唯一** → 两个并发跑的 link 测试不会互相读对方的交接文件 ---
	var handoff := "user://session_link_handoff_%s.txt" % _rand_hex()
	_fails += _check(not FileAccess.file_exists(handoff),
		"交接文件在开跑前不存在（不会读到上一次运行的残留）：%s" % handoff)

	# --- 房主子进程：放到后台线程里跑（必须与客户端**并发**）---
	# 候选窗口：起点随机、整体落在候选池内（父进程给子进程一个**确定性**的线性序列）。
	var win := PortAlloc.window(HOST_CANDIDATES)
	var base_port: int = win[0]
	var span: int = win.size()
	var host_args := _child_args(proj, "host", base_port, span, handoff)
	var host_out: Array = []
	var th := Thread.new()
	th.start(func() -> void: OS.execute(exe, host_args, host_out, true))

	# --- 等房主把端口占上：轮询**交接文件**（**不再用 OS.delay_msec(1500) 魔法延迟**）---
	var host_port := -1
	var deadline := Time.get_ticks_msec() + HANDOFF_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		host_port = read_handoff_port(handoff)
		if host_port > 0:
			break
		if not th.is_alive():
			# 房主线程已经结束，但交接文件还没出现 → **立即判失败**（不要干等满 15 秒）。
			break
		OS.delay_msec(HANDOFF_POLL_MS)
	_fails += _check(host_port > 0,
		"从交接文件拿到了房主实际占用的端口（实际 %d）" % host_port)

	# --- 客户端子进程：前台阻塞跑 ---
	var client_args := _child_args(proj, "client", host_port, 1, "-")
	var client_out: Array = []
	var client_code := OS.execute(exe, client_args, client_out, true)

	# --- 等房主退出 ---
	th.wait_to_finish()

	var host := _parse(host_out)
	var client := _parse(client_out)

	# ★ 交叉核对：交接文件里的端口 == 房主回报的 LINK|host_port（防交接文件写错）。
	_fails += _check(handoff_matches(host_port, int(host.get("host_port", "-1"))),
		"交接文件里的端口与房主回报的 LINK|host_port 一致（交接 %d / 回报 %s）"
		% [host_port, str(host.get("host_port", ""))])

	# 把房主实际占用的端口回报到本测试的 stdout：
	# 并发回归测试（tools/test_port_alloc.gd 的 A5）要**并发跑两份**本测试，
	# 再从两份输出里各取一个房主端口，断言它们**不同**。
	print("LINK|host_port=%d" % host_port)

	_fails += _check(host.has("DONE"), "房主子进程正常跑完并回报")
	_fails += _check(client.has("DONE"), "客户端子进程正常跑完并回报")
	_fails += _check(client_code == 0, "客户端子进程退出码为 0（实际 %d）" % client_code)
	_fails += _check(host.get("host_err", "") == "0",
		"房主建房成功（实际 err=%s）" % str(host.get("host_err", "")))
	_fails += _check(client.get("join_err", "") == "0",
		"客户端加入成功（实际 err=%s）" % str(client.get("join_err", "")))

	# --- ① 客户端收到了房主名单 ---
	_fails += _check(host.get("peer_count", "") == "2",
		"房主侧看到 2 人，实际 %s" % str(host.get("peer_count", "")))
	_fails += _check(client.get("peer_count", "") == "2",
		"客户端真的收到了房主名单（peer_count=2），实际 %s" % str(client.get("peer_count", "")))
	_fails += _check(host.get("roster", "") == client.get("roster", ""),
		"两端名单一致：房主 %s / 客户端 %s"
		% [str(host.get("roster", "")), str(client.get("roster", ""))])
	_fails += _check(client.get("is_host", "") == "0", "客户端不是房主")
	_fails += _check(host.get("is_host", "") == "1", "房主是房主")

	# --- ② 客户端拿到的是真实数据（不是 EncodedObjectAsID 占位符） ---
	_fails += _check(client.get("card_type", "") == "24/Mischief",
		"客户端收到的牌是重建出来的 Mischief 对象，实际类型 %s"
		% str(client.get("card_type", "")))
	_fails += _check(client.get("card_id", "") != "",
		"客户端能读出牌的 id（实际 '%s'）" % str(client.get("card_id", "")))
	_fails += _check(int(client.get("card_title_len", "0")) > 0,
		"客户端能读出牌的 title（长度 %s）" % str(client.get("card_title_len", "0")))
	_fails += _check(client.get("card_category", "") != "",
		"客户端能读出牌的 category（实际 '%s'）" % str(client.get("card_category", "")))
	_fails += _check(client.get("card_target_tag", "") != "",
		"客户端能读出牌的 target_tag（实际 '%s'）" % str(client.get("card_target_tag", "")))
	_fails += _check(client.get("card_needs_partner", "") in ["true", "false"],
		"客户端能读出牌的 needs_partner（实际 '%s'）" % str(client.get("card_needs_partner", "")))
	_fails += _check(float(client.get("card_duration", "0")) > 0.0,
		"客户端能读出牌的 duration（实际 %s）" % str(client.get("card_duration", "0")))
	_fails += _check(int(client.get("card_points", "-1")) >= 0,
		"客户端能读出牌的 points 且非负（实际 %s）" % str(client.get("card_points", "-1")))
	_fails += _check(client.get("round_started", "") == "1",
		"客户端收到清单时触发了 round_started，实际 %s 次" % str(client.get("round_started", "")))

	# --- ③ 房主超过 8 秒之后仍然健在（锁死 C3）---
	_fails += _check(int(host.get("alive_ms", "0")) > CONNECT_TIMEOUT_SEC * 1000,
		"房主活过了 %d 秒的连接超时窗口（实际 %d ms）"
		% [CONNECT_TIMEOUT_SEC, int(host.get("alive_ms", "0"))])
	_fails += _check(host.get("is_host", "") == "1",
		"房主过了超时窗口之后仍然是房主（没被自己的连接超时拆台）")
	_fails += _check(host.get("peer_count", "") == "2",
		"房主过了超时窗口之后房间还在（peer_count=%s）" % str(host.get("peer_count", "")))
	_fails += _check(int(client.get("alive_ms", "0")) > CONNECT_TIMEOUT_SEC * 1000,
		"客户端也活过了 %d 秒的窗口（实际 %d ms）"
		% [CONNECT_TIMEOUT_SEC, int(client.get("alive_ms", "0"))])
	_fails += _check(client.get("peer_count", "") == "2",
		"客户端过了超时窗口之后还连着（peer_count=%s）" % str(client.get("peer_count", "")))

	# --- ④ 客户端只有自己那一份清单 ---
	_fails += _check(client.get("deal_hands", "") == "1",
		"客户端只拿到 1 份清单（实际 %s 份）" % str(client.get("deal_hands", "")))
	_fails += _check(client.get("cards", "") == "3",
		"2 人局客户端那份是 3 张牌，不是整副牌（实际 %s 张）" % str(client.get("cards", "")))
	_fails += _check(client.get("card_ids", "") == host.get("client_hand_ids", ""),
		"客户端拿到的是房主映射给它的那一份（客户端 %s / 房主映射 %s）"
		% [str(client.get("card_ids", "")), str(host.get("client_hand_ids", ""))])
	_fails += _check(client.get("card_ids", "") != host.get("own_hand_ids", ""),
		"客户端拿到的不是房主自己那份")

	# --- 真实链路全程没断、也没报错 ---
	# 房主比客户端活得久，所以「客户端中途掉线」只能是链路真的出了问题。
	_fails += _check(client.get("conn_status", "") == "2",
		"客户端跑完时连接仍然是 CONNECTED（实际 status=%s）" % str(client.get("conn_status", "")))
	_fails += _check(client.get("conn_lost_ms", "") == "0",
		"客户端全程没有掉线（conn_lost_ms=%s）" % str(client.get("conn_lost_ms", "")))
	_fails += _check(client.get("roster_cleared_ms", "") == "0",
		"客户端的名单全程没有被清空过（roster_cleared_ms=%s）"
		% str(client.get("roster_cleared_ms", "")))
	_fails += _check(host.get("conn_status", "") == "2",
		"房主跑完时连接仍然是 CONNECTED（实际 status=%s）" % str(host.get("conn_status", "")))
	_fails += _check(int(host.get("exit_epoch_ms", "0")) > int(client.get("epoch_ms", "0")),
		"房主的退出时刻晚于客户端的回报时刻（房主 %s / 客户端 %s，epoch 毫秒）——房主先退会把客户端的连接掐断"
		% [str(host.get("exit_epoch_ms", "")), str(client.get("epoch_ms", ""))])
	_fails += _check(_no_engine_noise(host_out),
		"房主子进程输出里没有 ERROR / WARNING 行")
	_fails += _check(_no_engine_noise(client_out),
		"客户端子进程输出里没有 ERROR / WARNING 行")

	# --- ⑤ F2-3：Session 实例走的是生产用的 /root/Session 路径（两端都要一致）---
	_fails += _check(host.get("session_path", "") == "/root/Session",
		"房主子进程的 Session 在生产用的路径 /root/Session 上（实际 '%s'，来源 %s）"
		% [str(host.get("session_path", "")), str(host.get("session_source", ""))])
	_fails += _check(client.get("session_path", "") == "/root/Session",
		"客户端子进程的 Session 在生产用的路径 /root/Session 上（实际 '%s'，来源 %s）"
		% [str(host.get("session_path", "")), str(client.get("session_source", ""))])
	# `--script` 模式下 autoload 确实存在（修复轮 2 实测）→ 两端都直接用 autoload 实例
	_fails += _check(host.get("session_source", "") == "autoload",
		"房主子进程用的是 autoload 实例（实测 --script 模式下 autoload 存在）")
	_fails += _check(client.get("session_source", "") == "autoload",
		"客户端子进程用的是 autoload 实例（实测 --script 模式下 autoload 存在）")

	# --- ⑥ F2-2 反向自检：噪声探针证明「零 ERROR/WARNING」这条断言**有检测力** ---
	# 修复轮 1 时子进程用 `Engine.print_error_messages = false` 压掉了引擎日志，
	# 于是上面那两条断言**恒为 true**（虚假覆盖）。修复轮 2 恢复了引擎输出，
	# 并用第三个子进程（噪声探针）证明：真出现 ERROR/WARNING 时，它**确实会失败**。
	# 噪声探针：**不碰网络**（mode = "noise"），只是让参数形状与另外两个子进程一致。
	var noise_args := _child_args(proj, "noise", 0, 1, "-")
	var noise_out: Array = []
	var noise_code := OS.execute(exe, noise_args, noise_out, true)
	_fails += _check(noise_code == 0,
		"噪声探针子进程正常退出（实际 %d）" % noise_code)
	_fails += _check(_has_engine_noise(noise_out),
		"噪声探针子进程确实打出了 ERROR / WARNING 行（反向自检的前提）")
	_fails += _check(not _no_engine_noise(noise_out),
		"反向自检：噪声探针让「零 ERROR/WARNING」断言确实判失败（该断言有检测力，不是恒真）")

	# 收尾：删掉**自己刚创建的那一个**交接文件。
	#   路径是自己生成的唯一名字 → 转成绝对路径后精确删除，
	#   **不用通配符、不删其它路径**。
	_remove_own_handoff(handoff)

	print("")
	print("断言总数：%d" % _total)
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("---- 房主子进程输出 ----")
		for line in host_out:
			print("  H| " + str(line))
		print("---- 客户端子进程输出 ----")
		for line in client_out:
			print("  C| " + str(line))
		print("---- 噪声探针子进程输出 ----")
		for line in noise_out:
			print("  N| " + str(line))
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


## 子进程的启动参数（新契约）。
##     -- <mode> <base> <span> <handoff_path> [noise]
##   mode = "host" | "client" | "noise" | "portprobe"
##   base = 候选起始端口（host/portprobe）或具体端口（client）或 0（noise）
##   span = 候选个数（host/portprobe）或 1（client/noise）
##   handoff_path = 交接文件路径（host）或 "-"
func _child_args(proj: String, mode: String, base: int, span: int, handoff: String) -> PackedStringArray:
	return PackedStringArray([
		"--headless",
		"--path", proj,
		"--quit-after", CHILD_QUIT_AFTER,
		"--script", CHILD_SCRIPT,
		"--", mode, str(base), str(span), handoff,
	])


## 随机十六进制串（用来生成**唯一**的交接文件名）。
func _rand_hex() -> String:
	return "%08x%08x%08x" % [randi(), randi(), randi()]


## ------------------------------------------------------------------
## 【交接文件读写】
## ------------------------------------------------------------------
## ★ 这两个函数是**静态**的：tools/test_port_alloc.gd 的 A4 直接测它们 ——
##   测的是**真正被 link 测试使用的那一份实现**，不是复制品。
##
## 读交接文件里的端口号。
##
## ★ **失败必须明确**：路径为空 / 文件不存在 / 打不开 / 内容不是合法整数
##   → 返回 -1。
##   绝不能「静默当成 0 端口」（那会让父进程去连别人的服务器）
##   也不能「当作成功」。
static func read_handoff_port(path: String) -> int:
	if path == "" or path == "-":
		return -1
	if not FileAccess.file_exists(path):
		return -1
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var txt := f.get_as_text().strip_edges()
	f.close()
	# 端口号最多 5 位；用长度上限挡住溢出
	# （String.is_valid_int() **不防溢出**：对超长数字串它返回 true，
	#   但 int() 会溢出并打一条引擎 ERROR）。
	if txt.length() < 1 or txt.length() > 5:
		return -1
	if not txt.is_valid_int():
		return -1
	var p := txt.to_int()
	if p <= 0 or p > 65535:
		return -1
	return p


## 交接文件里的端口 == 子进程回报的端口？（交叉核对，防交接文件写错）
static func handoff_matches(handoff_port: int, reported_port: int) -> bool:
	return handoff_port > 0 and handoff_port == reported_port


## 删掉**自己刚创建的那一个**交接文件。
##
## ★ 路径是自己生成的唯一名字 → 转成绝对路径后**精确**删除，
##   **不用通配符、不删其它路径**。
func _remove_own_handoff(path: String) -> void:
	if path == "" or path == "-":
		return
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return
	var err := DirAccess.remove_absolute(abs_path)
	if err != OK:
		push_warning("[link] 交接文件删不掉：%s（err=%d）" % [abs_path, err])


## 解析子进程输出里的 `LINK|key=value` 行。
##
## **必须按换行拆开**：OS.execute 捕获回来的输出是**一整块多行文本**
## （返回的数组只有一个元素），不拆的话一条都读不到。
func _parse(out: Array) -> Dictionary:
	var d: Dictionary = {}
	for chunk in out:
		for raw in str(chunk).split("\n"):
			var line := raw.strip_edges()
			if not line.begins_with("LINK|"):
				continue
			var body := line.substr(5)
			var eq := body.find("=")
			if eq < 0:
				d[body] = "1"
			else:
				d[body.substr(0, eq)] = body.substr(eq + 1)
	return d


## 子进程输出里有没有引擎报错/告警行。
##
## ★ **匹配用 `contains` 而不是 `begins_with`**（修复轮 2 / N-A）：
##   实测（Godot 4.7.2）`push_error` 的行首是 `ERROR: <消息>`、
##   `push_warning` 是 `WARNING: <消息>`，但引擎还有 `USER ERROR:` / `SCRIPT ERROR:`
##   等其它前缀 —— `begins_with("ERROR")` 会**漏检**它们。
##   `contains("ERROR:")` / `contains("WARNING:")` 把这些前缀**全部**覆盖，
##   是**放宽**（更灵敏），不是收紧。
##   （实测证据见 task-7-report.md §3.2 的噪声探针原始输出。）
func _no_engine_noise(out: Array) -> bool:
	return not _has_engine_noise(out)


## 子进程输出里有没有引擎报错/告警行（`_no_engine_noise()` 的反面）。
func _has_engine_noise(out: Array) -> bool:
	for chunk in out:
		for raw in str(chunk).split("\n"):
			var line := raw.strip_edges()
			if line.contains("ERROR:") or line.contains("WARNING:"):
				return true
	return false


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
