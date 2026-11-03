extends SceneTree

## Task 7 修复轮 3（F3）：**端口动态分配**的回归测试。
##
## ------------------------------------------------------------------
## 【为什么需要这个文件】
## ------------------------------------------------------------------
## Task 6 / Task 7 的三个网络测试原本**硬编码**端口
## （27015-27024 / 27030-27034 / 27040-27041）。
## 固定端口 = 隐含「全局只有我一个人跑」的假设，而 SDD 流程里
## 「控制器跑统一入口」与「复审子代理跑测试」是**必然并发**的
## → 这个假设必然被打破 → 固定端口必然被抢 → 产生**假失败**。
##
## 实测（控制器 + 上一位复审子代理，两边都撞上过）：
##   * 占住 27040 → tools/test_session_link.gd 的 12 条断言连锁失败、退出码 1；
##     端口一释放，**立刻恢复 42/42 全绿**。
##   * 复审子代理首跑统一入口得到 7/9，单独重跑那两个文件全绿，重跑全量 9/9。
##
## → 本文件把「端口动态分配」这件事本身**锁成断言**，
##   以后谁把端口写死回去，这里立刻变红。
##
## ------------------------------------------------------------------
## 【5 组断言，每组都有反向自检】
## ------------------------------------------------------------------
##   A1 端口池与既有固定端口不重叠（且候选序列无重复、长度 == SPAN）
##   A2 占住端口 → 必须换下一个（**真实绑定裁决**有检测力）
##   A3 两个并发进程拿到**不同**的端口（并发安全的直接证据）
##   A4 交接文件机制有检测力（不存在 / 非法内容都必须明确失败）
##   A5 端到端并发回归：两份 tools/test_session_link.gd 并发跑，两份都必须通过
##
## ★ **A3 / A5 是本轮的核心回归锁**：改造前它们**必然失败**
##   （固定端口 → 必然撞车）。

const PortAlloc := preload("res://tools/port_alloc.gd")
## link 测试本体。A4 直接测它**真正使用的那一份**交接文件读写实现
## （静态函数），不是复制品 —— 否则 A4 就是自证。
const LinkTest := preload("res://tools/test_session_link.gd")
## 「端口探针」子进程脚本（tools/session_link_child.gd 的 portprobe 模式）。
const CHILD_SCRIPT := "res://tools/session_link_child.gd"
## 并发回归要跑的 link 测试脚本。
const LINK_SCRIPT := "res://tools/test_session_link.gd"
## 子进程的兜底退出帧数（跟 link 测试自己用的那个一样）。
const CHILD_QUIT_AFTER := "20000"

var _fails := 0
var _total := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	# ★ 本文件**不 await** 任何东西：所有等待都发生在 OS.execute（阻塞）里面。
	#   这样主线程的帧计数不会推进 → --quit-after 不会在测试跑到一半时把它掐掉。
	_a1_pool()
	_a2_occupied()
	_a3_concurrent()
	_a4_handoff()
	_a5_link_concurrent()

	print("")
	print("断言总数：%d" % _total)
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


## ------------------------------------------------------------------
## A1：端口池与既有固定端口不重叠
## ------------------------------------------------------------------
func _a1_pool() -> void:
	print("--- A1：端口池与既有固定端口不重叠 ---")
	var pool := PortAlloc.candidates()
	_fails += _check(pool.size() == PortAlloc.SPAN,
		"A1：候选序列长度 == SPAN（实际 %d，期望 %d）" % [pool.size(), PortAlloc.SPAN])
	_fails += _check(_all_in_pool(pool),
		"A1：候选端口全部落在 27100–27299 内（越界的 %s）" % str(_out_of_pool(pool)))
	_fails += _check(not _has_duplicate(pool),
		"A1：候选序列无重复")
	_fails += _check(not _overlaps(pool, PortAlloc.reserved()),
		"A1：候选序列与已固定占用的端口段（27015-27024 / 27030-27034 / 27040 / 27041 / 27050）无一重叠")

	# ★ 反向自检：同一个检测器在「故意越界 / 故意重叠」的窗口上**必须**判失败 ——
	#   否则上面那几条可能恒为 true（虚假覆盖）。
	var bad := PortAlloc.candidates(27015, 10, 0)
	_fails += _check(_overlaps(bad, PortAlloc.reserved()),
		"A1 反向自检：故意取在保留段上的窗口确实被判为重叠（重叠检测器有检测力）")
	_fails += _check(not _all_in_pool(bad),
		"A1 反向自检：故意取在保留段上的窗口确实被判为越界（范围检测器有检测力）")
	_fails += _check(not _has_duplicate(bad),
		"A1：确定性窗口（start_offset = 0）同样无重复")


## ------------------------------------------------------------------
## A2：占住端口 → 必须换下一个（真实绑定裁决有检测力）
## ------------------------------------------------------------------
func _a2_occupied() -> void:
	print("--- A2：占住端口 → 必须换下一个 ---")
	# 用**确定性**的起点（start_offset = 0），这样「第一个候选」是可预期的。
	var alloc_a := PortAlloc.new(PortAlloc.BASE, PortAlloc.SPAN, 0)
	_fails += _check(not alloc_a.exhausted(),
		"A2 前置：新分配器一开始不是耗尽的")
	var p1: int = alloc_a.next()
	_fails += _check(p1 == PortAlloc.BASE,
		"A2 前置：第一个候选就是候选段基准 %d（实际 %d）" % [PortAlloc.BASE, p1])

	# 用一个**真实的** ENetTransport 占住它。
	var holder := ENetTransport.new()
	var e_hold := holder.host(p1, 1)
	_fails += _check(e_hold == OK,
		"A2：真实绑定占住端口 %d 成功（实际 %d）" % [p1, e_hold])

	# ★ 反向自检：先证明「绑定失败」这件事本身**是可观测的** ——
	#   否则 A2 的后半段就是自证（两个都失败，什么都证明不了）。
	var thief := ENetTransport.new()
	Engine.print_error_messages = false
	var e_thief := thief.host(p1, 1)
	Engine.print_error_messages = true
	_fails += _check(e_thief != OK,
		"A2 反向自检：在被占端口上再 host **确实失败**（实际 %d）—— 证明绑定失败是可观测的" % e_thief)

	# 再要一个端口：拿候选 → 真实绑定 → 失败就换下一个。
	var alloc_b := PortAlloc.new(PortAlloc.BASE, PortAlloc.SPAN, 0)
	var first_tried := -1
	var attempts := 0
	var p2 := -1
	while not alloc_b.exhausted():
		var cand: int = alloc_b.next()
		if cand < 0:
			break
		if attempts == 0:
			first_tried = cand
		attempts += 1
		var t := ENetTransport.new()
		Engine.print_error_messages = false
		var e: Error = t.host(cand, 1)
		Engine.print_error_messages = true
		if e == OK:
			p2 = cand
			break
	_fails += _check(first_tried == p1,
		"A2：分配器**第一个**试的就是被占的那个端口 %d（实际 %d）" % [p1, first_tried])
	_fails += _check(attempts >= 2,
		"A2：至少试了 2 个候选（实际 %d）—— 证明它真的换到了下一个" % attempts)
	_fails += _check(p2 > 0,
		"A2：换到下一个候选之后**真实绑定成功**（实际端口 %d）" % p2)
	_fails += _check(p2 != p1,
		"A2：拿到的端口与被占的那个**不同**（%d vs %d）" % [p2, p1])

	# 清理（自己开的端口，自己关）
	_close(holder)
	_close(thief)


## ------------------------------------------------------------------
## A3：两个并发进程拿到**不同**的端口
## ------------------------------------------------------------------
func _a3_concurrent() -> void:
	print("--- A3：两个并发进程拿到不同的端口 ---")
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")

	# ★ 两个子进程**从同一个候选开始** → 它们会**真的抢同一个端口**
	#   → 输的那个必须换下一个候选。
	#   （如果给它们两个不同的窗口，就测不出「冲突时会不会换」。）
	var win := PortAlloc.window(8)
	var base_port: int = win[0]
	var span: int = win.size()
	var args_a := _probe_args(proj, base_port, span)
	var args_b := _probe_args(proj, base_port, span)

	var out_a: Array = []
	var codes: Array = []
	# 一个放后台线程、一个放前台（和 link 测试一样的写法）→ 真正**并发**。
	var th := Thread.new()
	th.start(func() -> void: codes.append(OS.execute(exe, args_a, out_a, true)))
	var out_b: Array = []
	var code_b := OS.execute(exe, args_b, out_b, true)
	th.wait_to_finish()
	var code_a := int(codes[0]) if codes.size() > 0 else -1

	var pa := _probe_port(out_a)
	var pb := _probe_port(out_b)
	_fails += _check(code_a == 0,
		"A3：并发子进程 A 退出码为 0（实际 %d）" % code_a)
	_fails += _check(code_b == 0,
		"A3：并发子进程 B 退出码为 0（实际 %d）" % code_b)
	_fails += _check(_probe_err(out_a) == 0 and _probe_err(out_b) == 0,
		"A3：两个子进程都是**真实绑定成功**的（A err=%d / B err=%d）"
		% [_probe_err(out_a), _probe_err(out_b)])
	_fails += _check(pa > 0,
		"A3：子进程 A 回报了一个端口（实际 %d）" % pa)
	_fails += _check(pb > 0,
		"A3：子进程 B 回报了一个端口（实际 %d）" % pb)
	_fails += _check(pa != pb,
		"A3：两个并发进程拿到**不同**的端口（%d vs %d）" % [pa, pb])
	_fails += _check(maxi(pa, pb) > base_port,
		"A3：至少有一个进程**换到了下一个候选**（两个端口 %d / %d，第一个候选是 %d）"
		% [pa, pb, base_port])
	_fails += _check(pa >= base_port and pa < base_port + span
			and pb >= base_port and pb < base_port + span,
		"A3：两个端口都落在父进程给的候选窗口内（%d / %d，窗口 [%d, %d)）"
		% [pa, pb, base_port, base_port + span])


## ------------------------------------------------------------------
## A4：交接文件机制有检测力
## ------------------------------------------------------------------
func _a4_handoff() -> void:
	print("--- A4：交接文件机制有检测力 ---")
	# 不存在 → 必须失败（不能静默当成 0 端口、也不能当作成功）
	var missing := "user://port_alloc_selftest_missing_%s.txt" % _rand_hex()
	_fails += _check(not FileAccess.file_exists(missing),
		"A4 前置：那个「不存在的交接文件」确实不存在")
	_fails += _check(LinkTest.read_handoff_port(missing) == -1,
		"A4：交接文件**不存在**时必须返回失败（不能静默当成 0 端口）")

	# 内容不是合法整数 → 必须失败
	var bad := "user://port_alloc_selftest_bad_%s.txt" % _rand_hex()
	_write_text(bad, "这不是端口\n")
	_fails += _check(FileAccess.file_exists(bad),
		"A4 前置：坏内容的交接文件确实写出来了")
	_fails += _check(LinkTest.read_handoff_port(bad) == -1,
		"A4：交接文件内容**不是合法整数**时必须返回失败")

	# 内容为空 → 必须失败
	var empty := "user://port_alloc_selftest_empty_%s.txt" % _rand_hex()
	_write_text(empty, "")
	_fails += _check(LinkTest.read_handoff_port(empty) == -1,
		"A4：交接文件内容为空时必须返回失败")

	# ★ 成功路径也要覆盖（否则上面的 -1 可能恒为 true —— 反向自检）
	var good := "user://port_alloc_selftest_good_%s.txt" % _rand_hex()
	_write_text(good, "27137\n")
	_fails += _check(LinkTest.read_handoff_port(good) == 27137,
		"A4：交接文件内容合法时读出正确的端口（实际 %d）"
		% LinkTest.read_handoff_port(good))
	_fails += _check(LinkTest.handoff_matches(27137, 27137),
		"A4：交接文件端口 == 子进程回报端口时判成功")
	_fails += _check(not LinkTest.handoff_matches(27137, 27138),
		"A4：交接文件端口 != 子进程回报端口时判失败")
	_fails += _check(not LinkTest.handoff_matches(-1, -1),
		"A4：两个都是无效值时**不得**判成功")

	# 清理自己创建的三个文件（精确路径，不用通配符）
	_remove_file(bad)
	_remove_file(empty)
	_remove_file(good)


## ------------------------------------------------------------------
## A5：端到端并发回归（两份 link 测试并发跑）
## ------------------------------------------------------------------
func _a5_link_concurrent() -> void:
	print("--- A5：端到端并发回归（两份 link 测试并发跑）---")
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var args_a := _link_args(proj)
	var args_b := _link_args(proj)

	var out_a: Array = []
	var codes: Array = []
	# 一个放后台线程、一个放前台 → 两份 link 测试**真正并发**。
	var th := Thread.new()
	th.start(func() -> void: codes.append(OS.execute(exe, args_a, out_a, true)))
	var out_b: Array = []
	var code_b := OS.execute(exe, args_b, out_b, true)
	th.wait_to_finish()
	var code_a := int(codes[0]) if codes.size() > 0 else -1

	var pa := _link_host_port(out_a)
	var pb := _link_host_port(out_b)
	_fails += _check(code_a == 0,
		"A5：并发跑的 link 测试 A 退出码为 0（实际 %d）" % code_a)
	_fails += _check(code_b == 0,
		"A5：并发跑的 link 测试 B 退出码为 0（实际 %d）" % code_b)
	_fails += _check(_text(out_a).contains("TEST PASSED"),
		"A5：并发跑的 link 测试 A 输出含 TEST PASSED")
	_fails += _check(_text(out_b).contains("TEST PASSED"),
		"A5：并发跑的 link 测试 B 输出含 TEST PASSED")
	_fails += _check(pa > 0,
		"A5：link 测试 A 回报了房主端口（实际 %d）" % pa)
	_fails += _check(pb > 0,
		"A5：link 测试 B 回报了房主端口（实际 %d）" % pb)
	_fails += _check(pa != pb,
		"A5：两份 link 测试的房主端口**不同**（%d vs %d）" % [pa, pb])


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

## 「端口探针」子进程的启动参数（mode = "portprobe"）。
func _probe_args(proj: String, base: int, span: int) -> PackedStringArray:
	return PackedStringArray([
		"--headless",
		"--path", proj,
		"--quit-after", CHILD_QUIT_AFTER,
		"--script", CHILD_SCRIPT,
		"--", "portprobe", str(base), str(span), "-",
	])


## link 测试的启动参数（A5 用）。
func _link_args(proj: String) -> PackedStringArray:
	return PackedStringArray([
		"--headless",
		"--path", proj,
		"--quit-after", CHILD_QUIT_AFTER,
		"--script", LINK_SCRIPT,
	])


## 子进程输出里的 `LINK|host_port=` （-1 = 没找到）。
func _probe_port(out: Array) -> int:
	return _link_value(out, "host_port")


## 子进程输出里的 `LINK|probe_err=` （-1 = 没找到）。
func _probe_err(out: Array) -> int:
	return _link_value(out, "probe_err")


## link 测试输出里的 `LINK|host_port=` （-1 = 没找到）。
func _link_host_port(out: Array) -> int:
	return _link_value(out, "host_port")


## 从子进程输出里取 `LINK|<key>=<int>` 的值（-1 = 没找到 / 不是整数）。
##
## ★ **必须按换行拆开**：OS.execute 捕获回来的输出是**一整块多行文本**
##   （返回的数组只有一个元素），不拆的话一条都读不到。
func _link_value(out: Array, key: String) -> int:
	var prefix := "LINK|" + key + "="
	for chunk in out:
		for raw in str(chunk).split("\n"):
			var line := raw.strip_edges()
			if not line.begins_with(prefix):
				continue
			var v := line.substr(prefix.length()).strip_edges()
			if v.length() >= 1 and v.length() <= 5 and v.is_valid_int():
				return v.to_int()
	return -1


## 子进程输出拼成一整段文本（用来找 "TEST PASSED"）。
func _text(out: Array) -> String:
	var parts: Array[String] = []
	for chunk in out:
		parts.append(str(chunk))
	return "\n".join(parts)


## 候选端口是不是全在候选段 [BASE, BASE+SPAN) 内。
func _all_in_pool(pool: Array) -> bool:
	for p in pool:
		if int(p) < PortAlloc.BASE or int(p) >= PortAlloc.BASE + PortAlloc.SPAN:
			return false
	return true


## 越界的那几个端口（诊断用）。
func _out_of_pool(pool: Array) -> Array:
	var out: Array = []
	for p in pool:
		if int(p) < PortAlloc.BASE or int(p) >= PortAlloc.BASE + PortAlloc.SPAN:
			out.append(int(p))
	return out


## 序列里有没有重复。
func _has_duplicate(pool: Array) -> bool:
	var seen: Array = []
	for p in pool:
		if seen.has(int(p)):
			return true
		seen.append(int(p))
	return false


## 两个端口集合有没有交集。
func _overlaps(a: Array, b: Array) -> bool:
	for p in a:
		if b.has(int(p)):
			return true
	return false


## 随机十六进制串（用来生成**唯一**的临时文件名）。
func _rand_hex() -> String:
	return "%08x%08x%08x" % [randi(), randi(), randi()]


## 写一个文本文件（自己创建的路径，用完自己删）。
func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()


## 删掉**自己刚创建的那一个**文件（精确路径，不用通配符）。
func _remove_file(path: String) -> void:
	if path == "" or not FileAccess.file_exists(path):
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## 关掉一个 transport 自己开的 peer。
func _close(t: ENetTransport) -> void:
	if t == null:
		return
	var p := t.get_peer()
	if p != null and p.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		p.close()


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
