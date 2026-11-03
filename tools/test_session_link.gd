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
##   * 子进程用 OS.get_cmdline_user_args() 读 `--` 之后的 mode / port
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
## 【端口】27040（避开 Task 6 的 27015-27024 与 Task 7 单进程测试的 27030-27033）。
##
## 【断言的 4 件事】
##   ① 客户端收到了房主名单 → 两边 peer_count 一致且 == 2
##   ② 客户端拿到的是**真实数据**（能读出 id/title/category/target_tag，
##      且不是 EncodedObjectAsID 占位符）
##   ③ 房主**超过 8 秒之后仍然健在**（直接锁死 C3）
##   ④ 客户端收到的**只有自己那一份**清单（不泄漏别人的）

const HOST_PORT := 27040
## 噪声探针子进程用的端口（**不碰网络**，只是让参数形状与另外两个子进程一致）。
const NOISE_PORT := 27041
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

var _fails := 0
var _total := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")

	# --- 房主子进程：放到后台线程里跑（必须与客户端**并发**）---
	var host_args := _child_args(proj, "host", HOST_PORT)
	var host_out: Array = []
	var th := Thread.new()
	th.start(func() -> void: OS.execute(exe, host_args, host_out, true))

	# 等房主把端口占上（否则客户端会连不上）
	OS.delay_msec(1500)

	# --- 客户端子进程：前台阻塞跑 ---
	var client_args := _child_args(proj, "client", HOST_PORT)
	var client_out: Array = []
	var client_code := OS.execute(exe, client_args, client_out, true)

	# --- 等房主退出 ---
	th.wait_to_finish()

	var host := _parse(host_out)
	var client := _parse(client_out)

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
	var noise_args := _child_args(proj, "host", NOISE_PORT, "noise")
	var noise_out: Array = []
	var noise_code := OS.execute(exe, noise_args, noise_out, true)
	_fails += _check(noise_code == 0,
		"噪声探针子进程正常退出（实际 %d）" % noise_code)
	_fails += _check(_has_engine_noise(noise_out),
		"噪声探针子进程确实打出了 ERROR / WARNING 行（反向自检的前提）")
	_fails += _check(not _no_engine_noise(noise_out),
		"反向自检：噪声探针让「零 ERROR/WARNING」断言确实判失败（该断言有检测力，不是恒真）")

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


## 子进程的启动参数。
## `flag` 非空时追加为**第三个** user arg（噪声探针用）。
func _child_args(proj: String, mode: String, port: int, flag: String = "") -> PackedStringArray:
	var args := PackedStringArray([
		"--headless",
		"--path", proj,
		"--quit-after", CHILD_QUIT_AFTER,
		"--script", CHILD_SCRIPT,
		"--", mode, str(port),
	])
	if flag != "":
		args.append(flag)
	return args


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
