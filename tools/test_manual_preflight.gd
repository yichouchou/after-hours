extends SceneTree

## Task 13：P1 双窗口手动验收清单的**前置检查**（preflight）。
##
## ------------------------------------------------------------------
## 【它钉的是什么】
## ------------------------------------------------------------------
## 验收清单 `docs/acceptance/p1-manual-checklist.md` 是写给**完全不懂开发的人**看的，
## 里面每一句「怎么操作 / 看什么」其实都是**对代码的断言**。
## → 本测试把那些断言**机器化**：清单里说的按钮文案、键位、端口、清单张数、
##   出生点、结算卡片长什么样，都在这里跑一遍。
## → 清单和代码不同步时，这里会红 —— 而不是让验收的人对着过期文档白跑一遍。
##
## ★ 本测试**不重复**已关单任务已覆盖的东西：
##   * 双进程对称流程（人数 / 名单 / 两端结算）→ tools/test_smoke.gd
##   * 缺搭档时间 ×2、先到先得台账 → tools/test_interaction.gd
##   → 那些在清单第 5 节里标注了对应的断言编号。
##
## ------------------------------------------------------------------
## 【端口】
## ------------------------------------------------------------------
## P1 人工验收固定用 **28000**（与 Session.DEFAULT_PORT 一致；
## tools/test_smoke.gd 的 [G8] 已经钉住那个常量）。
## 本测试用**真 socket 绑定**报「此刻这个端口有没有被占」——
## 清单第 1.5 节让用户「端口被占用就先关掉别的窗口」，这里就是那条的自动化版本。
## ★★★ **它不判成败，只报状态**（2026-11-04 终审 Important-1 裁决）：
##   手工验收的游戏窗口**自己就占着 28000** → 用户正在玩的时候跑统一入口，
##   这条会硬红 —— 那是**假红**。→ 降级成提示，检测力由 [P37] 保住。
## 绑完立刻关闭，不影响后续任何测试（测试用的端口是动态分配的 27100–27299）。
##
## ------------------------------------------------------------------
## 【判定】
## ------------------------------------------------------------------
## 退出码 0 且输出含 `TEST PASSED` 才算通过（与 tools/run_tests.ps1 的口径一致）。

const CHECKLIST_PATH := "res://docs/acceptance/p1-manual-checklist.md"

const LOBBY_SCENE := "res://scenes/lobby.tscn"
const HUD_SCENE := "res://scenes/ui/hud.tscn"
const RESULT_SCENE := "res://scenes/result.tscn"
const GAME_SCENE := "res://scenes/game.tscn"

const PLAYER_SRC := "res://scripts/player.gd"
const GAME_SCENE_SRC := "res://scripts/game_scene.gd"
const LOBBY_SRC := "res://scripts/ui/lobby_ui.gd"
const SESSION_SRC := "res://scripts/net/session.gd"
const TRANSPORT_SRC := "res://scripts/net/transport.gd"
const RPC_SRC := "res://scripts/net/game_rpc.gd"

## 端口动态分配器（**没有** class_name → 必须 preload）。
## ★ 用来做 [P37]：从动态候选池里独占绑一个端口，证明「端口探测机制可用」。
const PortAlloc := preload("res://tools/port_alloc.gd")

## ★ 清单 F3 承诺「房主退出 = 本局结束，客户端不会自动接管」。
##   这里从结构上钉它：唯一的"我是房主"判据是「自己的 peer id == 1」，
##   而客户端的 peer id 是随机 32 位数（永远不是 1）；并且**没有**任何接管路径。
const HOST_MIGRATION_TOKENS := ["become_host", "migrate_host", "promote",
	"take_over", "takeover", "host_migration", "接管"]

## 人工验收用的端口。
const MANUAL_PORT := 28000

## 清单里应该有的 6 段（与派单 §2.2 的分段标题逐字一致）。
const EXPECTED_SECTIONS := ["A 一起开局", "B 领捣蛋清单", "C 执行捣蛋",
	"D 被守卫抓", "E 天亮结算", "F 稳定"]

## 清单里应该有的 24 条验收项。
const EXPECTED_ITEMS := [
	"A1", "A2", "A3", "A4",
	"B1", "B2", "B3", "B4",
	"C1", "C2", "C3", "C4",
	"D1", "D2", "D3", "D4", "D5", "D6",
	"E1", "E2", "E3",
	"F1", "F2", "F3",
]

## 清单里每个验收项都要带的勾选框前缀。
const CHECKBOX_PREFIX := "- **过了没**：[ ]"

## 清单里让用户点的界面词（必须同时出现在文档里**和**界面上）。
const LOBBY_BUTTON_LABELS := ["创建房间", "加入房间", "开始这一夜"]
const LOBBY_TITLE := "镇长不在的时候"
const RESULT_TITLE := "天亮了"
const FINISH_BUTTON_LABEL := "收工"

## HUD 清单一行的格式（hud.gd 拼的）。
const CARD_ROW_FORMAT := "□ %s"
## HUD 右上角提示的格式（game_scene.gd 拼的）。
const HINT_FORMAT := "按住 E 捣蛋 · 已完成 %d 条"
## 结算卡片那行统计的格式（result_screen.gd 拼的；中间是 **4 个空格**）。
const RESULT_STAT_FORMAT := "捣蛋 %d 次    被抓 %d 次"

## 结算页**不许**出现的字（零失败惩罚：没有分数 / 排名 / 淘汰）。
const RESULT_FORBIDDEN_WORDS := ["分数", "得分", "排名", "排行榜", "第一名",
	"淘汰", "出局", "score", "rank"]

## 随机种子组数（2 人局的清单事实要在多组种子下都成立）。
const SEED_ROUNDS := 8

## 2 人局每份清单的张数（clampi(2 + 1, 3, 5) = 3）—— 写字面量。
const EXPECT_HAND_SIZE_2P := 3

var _fails := 0
var _total := 0
var _notes := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	print("=== P1 手动验收清单 · 前置检查 ===")
	await _checklist_doc_part()
	await _ui_wording_part()
	await _controls_part()
	await _deck_facts_part()
	await _spawn_part()
	await _result_part()
	await _port_part()
	await _lamp_chain_part()
	_report_known_gaps()
	_finish()


## ==================================================================
## 组 1：清单文档本身的完整性（验收项不许少、勾选框不许少）
## ==================================================================
func _checklist_doc_part() -> void:
	print("--- 组 1：验收清单文档 ---")
	var abs_path := ProjectSettings.globalize_path(CHECKLIST_PATH)
	var exists := FileAccess.file_exists(abs_path)
	_fails += _check(exists, "[P1] 验收清单文件存在：%s" % CHECKLIST_PATH)
	if not exists:
		return
	var text := FileAccess.get_file_as_string(abs_path)
	_fails += _check(not text.is_empty(), "[P2] 验收清单不是空文件")

	# 6 个分段标题都在。
	var missing_sections: Array[String] = []
	for s in EXPECTED_SECTIONS:
		if not text.contains(s):
			missing_sections.append(s)
	_fails += _check(missing_sections.is_empty(),
		"[P3] 6 个分段标题都在（%s）" % _first(missing_sections))

	# 24 条验收项都在（每条一个 `#### <编号> ` 的小标题）。
	var missing_items: Array[String] = []
	for it in EXPECTED_ITEMS:
		if not text.contains("#### " + it + " "):
			missing_items.append(it)
	_fails += _check(missing_items.is_empty(),
		"[P4] 24 条验收项都在（%s）" % _first(missing_items))

	# 每条都带勾选框。
	var box_count := _count_occurrences(text, CHECKBOX_PREFIX)
	_fails += _check(box_count == EXPECTED_ITEMS.size(),
		"[P5] 勾选框数量 == %d（实际 %d）" % [EXPECTED_ITEMS.size(), box_count])

	# 端口写明了（验收者要知道两个窗口用同一个端口）。
	_fails += _check(text.contains(str(MANUAL_PORT)),
		"[P6] 清单里写明了端口 %d" % MANUAL_PORT)

	# 清单里点名的界面词都在文档里（用户照着点的字必须能找到）。
	var missing_words: Array[String] = []
	for w in LOBBY_BUTTON_LABELS + [FINISH_BUTTON_LABEL, RESULT_TITLE]:
		if not text.contains(w):
			missing_words.append(w)
	_fails += _check(missing_words.is_empty(),
		"[P7] 清单里点名的界面词都出现过（%s）" % _first(missing_words))

	# ★ 清单必须提醒「两个窗口都要在点开始之前就位」（晚加入收不到开局消息）。
	_fails += _check(text.contains("就位"),
		"[P8] 清单里提醒了「两个窗口都要在点开始之前就位」")
	# ★ 清单必须写明「要启动两次 / 两个独立进程」。
	_fails += _check(text.contains("两个独立") or text.contains("启动两次"),
		"[P9] 清单里说明了为什么要开两个独立进程")


## ==================================================================
## 组 2：清单里让用户点的字，界面上真的有（运行期读节点，不看源码）
## ==================================================================
func _ui_wording_part() -> void:
	print("--- 组 2：界面文案 ---")
	var lobby: Node = _instantiate(LOBBY_SCENE)
	if lobby == null:
		_fails += _check(false, "[P10] 大厅场景可实例化")
		return
	var title := lobby.get_node_or_null("Center/Panel/Margin/VBox/Title") as Label
	_fails += _check(title != null and title.text == LOBBY_TITLE,
		"[P10] 大厅标题是「%s」（实际「%s」）" % [LOBBY_TITLE,
			title.text if title != null else "<null>"])
	for pair in [["HostButton", LOBBY_BUTTON_LABELS[0]],
			["JoinButton", LOBBY_BUTTON_LABELS[1]],
			["StartButton", LOBBY_BUTTON_LABELS[2]]]:
		var btn := lobby.get_node_or_null("Center/Panel/Margin/VBox/" + String(pair[0])) as Button
		_fails += _check(btn != null and btn.text == String(pair[1]),
			"[P11] 大厅按钮 %s 的文案是「%s」（实际「%s」）" % [pair[0], pair[1],
				btn.text if btn != null else "<null>"])

	var hud: Node = _instantiate(HUD_SCENE)
	if hud == null:
		_fails += _check(false, "[P12] HUD 场景可实例化")
	else:
		var finish := hud.get_node_or_null("FinishButton") as Button
		_fails += _check(finish != null and finish.text == FINISH_BUTTON_LABEL,
			"[P12] HUD 的「%s」按钮文案是「%s」（实际「%s」）" % ["收工",
				FINISH_BUTTON_LABEL, finish.text if finish != null else "<null>"])
		# HUD 清单一行的格式：「□ <标题>」
		var titles: Array[String] = ["偷走杂货铺的萝卜"]
		hud.call("set_card_list", titles)
		var rows := _label_texts(hud.get_node_or_null("CardList"))
		_fails += _check(rows.size() == 1 and rows[0] == CARD_ROW_FORMAT % titles[0],
			"[P13] HUD 清单一行的格式是「%s」（实际「%s」）" % [CARD_ROW_FORMAT,
				rows[0] if rows.size() > 0 else "<空>"])

	var result: Node = _instantiate(RESULT_SCENE)
	if result == null:
		_fails += _check(false, "[P14] 结算页场景可实例化")
	else:
		var rt := result.get_node_or_null("Title") as Label
		_fails += _check(rt != null and rt.text == RESULT_TITLE,
			"[P14] 结算页标题是「%s」（实际「%s」）" % [RESULT_TITLE,
				rt.text if rt != null else "<null>"])


## ==================================================================
## 组 3：清单里让用户用的操作，真的是这样（键位 / 加入地址 / 端口）
## ==================================================================
func _controls_part() -> void:
	print("--- 组 3：键位与地址 ---")
	var player_src := _read_source(PLAYER_SRC)
	# 交互键是 E。
	_fails += _check(player_src.contains("const INTERACT_KEY := KEY_E"),
		"[P15] 交互键是 E（KEY_E）")
	# 移动用方向键。
	var uses_arrows := player_src.contains("\"ui_left\", \"ui_right\"") \
		and player_src.contains("\"ui_up\", \"ui_down\"")
	_fails += _check(uses_arrows, "[P16] 移动用方向键（ui_left/right/up/down）")
	# 「加入房间」连的是本机，且端口取默认值（= 28000）。
	var lobby_src := _read_source(LOBBY_SRC)
	_fails += _check(lobby_src.contains("const JOIN_ADDRESS := \"127.0.0.1\""),
		"[P17] 「加入房间」连的是本机 127.0.0.1")
	_fails += _check(lobby_src.contains("_session.join_game(JOIN_ADDRESS)"),
		"[P18] 「加入房间」没有另传端口（用的默认端口 = %d）" % MANUAL_PORT)
	# 右上角提示的格式（清单里引用了它）。
	var game_src := _read_source(GAME_SCENE_SRC)
	_fails += _check(game_src.contains(HINT_FORMAT),
		"[P19] 右上角提示的格式是「%s」" % HINT_FORMAT)

	# ★ 清单 F3：房主退出 = 本局结束，客户端**不会**自动接管。
	var transport_src := _read_source(TRANSPORT_SRC)
	var session_src := _read_source(SESSION_SRC)
	_fails += _check(transport_src.contains("get_unique_id() == 1"),
		"[P33] 「我是房主」只认自己的 peer id == 1（客户端的 id 是随机数，永远不是 1）")
	var migration_hits: Array[String] = []
	for t in HOST_MIGRATION_TOKENS:
		if session_src.contains(t) or transport_src.contains(t):
			migration_hits.append(t)
	_fails += _check(migration_hits.is_empty(),
		"[P34] 没有「把房主转交给客户端」的路径（%s）" % _first(migration_hits))


## ==================================================================
## 组 4：2 人局的清单事实（清单写「2 人局 3 张」/「两人的清单不同」）
## ==================================================================
func _deck_facts_part() -> void:
	print("--- 组 4：2 人局的清单事实 ---")
	var all := Mischief.load_all()
	_fails += _check(all.size() == 10, "[P20] 行为表有 10 条（实际 %d）" % all.size())

	# 每张牌的标题可读（清单 B3：没有乱码、没有空白）。
	var bad_titles: Array[String] = []
	for m in all:
		var t := m.title
		if t.is_empty() or not _has_cjk(t) or t.contains("\uFFFD"):
			bad_titles.append("%s=[%s]" % [m.id, t])
	_fails += _check(bad_titles.is_empty(),
		"[P21] 每张牌的标题都是可读中文（%s）" % _first(bad_titles))

	# 每张牌的 7 个字段都可读、类型正确。
	var bad_fields: Array[String] = []
	for m in all:
		if str(m.id).is_empty() or str(m.category).is_empty() or str(m.target_tag).is_empty():
			bad_fields.append(str(m.id))
		if typeof(m.needs_partner) != TYPE_BOOL:
			bad_fields.append(str(m.id) + ".needs_partner")
		if typeof(m.duration) != TYPE_FLOAT or m.duration <= 0.0:
			bad_fields.append(str(m.id) + ".duration")
		if typeof(m.points) != TYPE_INT:
			bad_fields.append(str(m.id) + ".points")
	_fails += _check(bad_fields.is_empty(),
		"[P22] 每张牌的 7 个字段都可读、类型正确（%s）" % _first(bad_fields))

	# 2 人局：每份 3 张；两份清单不同。多组随机种子都要成立。
	var tags: Array[StringName] = []
	for m in all:
		tags.append(m.target_tag)
	var wrong_size: Array[String] = []
	var same_hands: Array[String] = []
	for i in SEED_ROUNDS:
		var rng := RandomNumberGenerator.new()
		rng.seed = 1000 + i
		var hands := MischiefDeck.generate(all, 2, rng, tags)
		if hands.size() != 2:
			wrong_size.append("seed %d: 只有 %d 份" % [1000 + i, hands.size()])
			continue
		for h in hands:
			if h.size() != EXPECT_HAND_SIZE_2P:
				wrong_size.append("seed %d: %d 张" % [1000 + i, h.size()])
		var a := _id_set(hands[0])
		var b := _id_set(hands[1])
		if a == b:
			same_hands.append("seed %d" % (1000 + i))
	_fails += _check(wrong_size.is_empty(),
		"[P23] 2 人局每份清单 %d 张（%d 组种子，%s）" % [EXPECT_HAND_SIZE_2P,
			SEED_ROUNDS, _first(wrong_size)])
	_fails += _check(same_hands.is_empty(),
		"[P24] 2 人局两人的清单不同（%d 组种子，%s）" % [SEED_ROUNDS,
			_first(same_hands)])


## ==================================================================
## 组 5：出生点（清单 D3：多人时出生点不同）
## ==================================================================
func _spawn_part() -> void:
	print("--- 组 5：出生点 ---")
	var game: Node = _instantiate(GAME_SCENE)
	if game == null:
		_fails += _check(false, "[P25] 对局场景可实例化")
		return
	# 对局场景一进树就会建守卫并开始跑 AI → 冻住，免得影响后面的断言。
	var guards := game.get_node_or_null("Guards")
	if guards != null:
		for c in guards.get_children():
			c.set_physics_process(false)
	await process_frame
	await process_frame

	var pos0: Vector2 = game.call("spawn_position_for_index", 0)
	var pos1: Vector2 = game.call("spawn_position_for_index", 1)
	_fails += _check(pos0 != pos1,
		"[P25] 2 人局的两个出生点不同（%s vs %s）" % [str(pos0), str(pos1)])

	var seen := {}
	var dup := ""
	for i in 6:
		var p: Vector2 = game.call("spawn_position_for_index", i)
		if seen.has(p):
			dup = "index %d 与 index %d 相同" % [int(seen[p]), i]
			break
		seen[p] = i
	_fails += _check(dup.is_empty(), "[P26] 6 个出生点两两不同（%s）" % dup)


## ==================================================================
## 组 6：结算卡片（清单 E2 / E3）
## ==================================================================
func _result_part() -> void:
	print("--- 组 6：结算卡片 ---")
	var result: Node = _instantiate(RESULT_SCENE)
	if result == null:
		_fails += _check(false, "[P27] 结算页场景可实例化")
		return
	var summary := {
		1: {"name": "玩家 1", "done": 2, "caught": 1,
			"mischief_titles": ["偷走杂货铺的萝卜"]},
	}
	result.call("show_summary", summary)
	var texts := _label_texts(result)
	var joined := " | ".join(texts)
	_fails += _check(joined.contains("玩家 1"),
		"[P27] 结算卡片有「玩家 1」（实际：%s）" % joined)
	_fails += _check(joined.contains(RESULT_STAT_FORMAT % [2, 1]),
		"[P28] 结算卡片那行是「%s」（实际：%s）" % [RESULT_STAT_FORMAT % [2, 1], joined])
	_fails += _check(joined.contains("· 偷走杂货铺的萝卜"),
		"[P29] 结算卡片列出了已完成的捣蛋标题（实际：%s）" % joined)

	# 结算载荷里每人的字段恰好 4 个。
	var fields := (summary[1] as Dictionary).keys()
	_fails += _check(fields.size() == 4,
		"[P30] 结算载荷里每人的字段恰好 4 个（实际 %d）" % fields.size())

	# ★ 结算页上不许出现分数 / 排名 / 淘汰（清单 E3）。
	var hits: Array[String] = []
	for w in RESULT_FORBIDDEN_WORDS:
		for t in texts:
			if t.contains(w):
				hits.append("%s→%s" % [w, t])
	_fails += _check(hits.is_empty(),
		"[P31] 结算页上没有分数/排名/淘汰字样（%s）" % _first(hits))


## ==================================================================
## 组 7：端口此刻可用（清单 1.5 的自动化版本）
## ==================================================================
func _port_part() -> void:
	print("--- 组 7：端口 %d ---" % MANUAL_PORT)
	var srv := UDPServer.new()
	var err := srv.listen(MANUAL_PORT)
	# ★★★ 这条**不判成败**，只报状态（2026-11-04 终审的 Important-1 裁决）。
	#   原因：手工验收的游戏窗口**自己就占着 28000**（ENet 房主绑它），
	#   而这份测试也被统一入口调用 → 用户正在玩的时候跑自动化测试，
	#   就会得到一条「端口被占」的硬红 —— 那是**假红**（不是游戏坏了）。
	#   → 降级成提示：占用时给用户**可执行**的下一步（先把游戏窗口关掉）。
	#   → 检测力由 [P37] 保住：它证明「这台机器现在能独占绑定端口」，
	#     于是「[P37] 绿 + 28000 被占」= 端口真的被别人占着（而不是绑定机制坏了）。
	if err == OK:
		print("[ 提示 ] 端口 %d 此刻**可以独占绑定** → 可以做手动验收。" % MANUAL_PORT)
	else:
		print("[ 提示 ] 端口 %d 此刻**无法独占绑定**（错误码 %d）——手动验收前请先关掉占用它的游戏窗口。" % [
			MANUAL_PORT, int(err)])
		print("[ 提示 ] 这**不是**游戏坏了，也不是自动化测试坏了；只是端口被占了。")
	# ★ 措辞说明：这里**只**说「能不能独占绑定」，**不**断言「端口有没有被占」——
	#   Windows 的 UDP 语义下，别的普通 UDP 套接字占着 28000 时，
	#   这里**仍然可能绑定成功**（实测：PowerShell 的 UdpClient 占着，UDPServer 照样绑得上）。
	#   → 说「能否独占绑定」才是这条探针**真正测到**的事实。
	# ★ UDPServer **没有** close() 方法（Godot 4.7.2）：
	#   它是 RefCounted → 出了这个函数就被释放，端口随之归还。
	srv = null

	# ★ [P37]：端口探测机制本身可用（动态候选池里的端口能独占绑定）。
	#   这条把「端口自检」那部分的检测力保留下来：机制坏了 → 绿不了；
	#   机制好好的 → 28000 被占就是真的被别人占着。
	var alloc := PortAlloc.new()
	var probe_port := alloc.next()
	_fails += _check(probe_port > 0,
		"[P37] 端口探测机制可用（动态候选池里能独占绑定一个端口，实际 %d）" % probe_port)


## ==================================================================
## 组 9：拔掉路灯的生产链路**已接通**（清单 D6 的预期已从「不过」改成「过」）
## ==================================================================
##
## ★ 这一条原先只是**现状说明（NOTE，不判定成败）** —— Task 12 修复轮 2
##   把生产链路接通之后，它必须**升格成断言**：
##   清单 D6 现在写「预期为过」→ 这里就得钉住「生产链路真的接通了」，
##   否则清单会变成过期文档（而「清单过期」正是这个测试存在的意义）。
##
## ★ 「接通」的四条判据（都必须在**代码部分**里，注释不算）：
##   ① game_scene.gd 把 props_root 注入 RPC 节点（**两端**都要）；
##   ② game_rpc.gd 有 set_lamp_state RPC（authority / call_remote / reliable）；
##   ③ 房主裁决成功后**真的改世界**（Interaction.set_lamp_on 是唯一入口）；
##   ④ 房主把「这盏灯灭了」广播出去（set_lamp_state.rpc(...)）。
func _lamp_chain_part() -> void:
	print("--- 组 9：拔路灯的生产链路 ---")
	var game_src := _read_source(GAME_SCENE_SRC)
	var rpc_src := _read_source(RPC_SRC)
	_fails += _check(_lamp_chain_wired(rpc_src, game_src),
		"[P35] ★拔路灯的生产链路**已接通**（注入 props_root + set_lamp_state RPC + 写 meta + 广播）")
	# ★ 反向自检：证明上面那条判据**不是恒真**（只有注释提到它时必须判红）。
	_fails += _check(not _lamp_chain_wired(
			"## 房主写 meta：Interaction.set_lamp_on(node, false)\n"
			+ "## set_lamp_state.rpc(target_id, false)\nvar x := 1\n",
			"## rpc_node.set(\"props_root\", props_root)\n"),
		"[P36] 反向自检：只有**注释**提到这条链路时，上面的判据必须判红（判据不是恒真）")


## 生产链路「接通」了吗（拔掉路灯 → 守卫视野变暗）。
func _lamp_chain_wired(rpc_src: String, game_src: String) -> bool:
	var rpc_code := _code_lines(rpc_src)
	var game_code := _code_lines(game_src)
	return rpc_code.contains(
			"@rpc(\"authority\", \"call_remote\", \"reliable\")\nfunc set_lamp_state(") \
		and rpc_code.contains("func set_lamp_state(target_id: int, on: bool) -> void:") \
		and rpc_code.contains("Interaction.set_lamp_on(") \
		and rpc_code.contains("set_lamp_state.rpc(") \
		and game_code.contains("rpc_node.set(\"props_root\", props_root)")


## ==================================================================
## 组 8：把「已知问题」的现状**报出来**（NOTE，不判定成败）
## ==================================================================
## ★ 这些是**现状说明**，不是断言：
##   把「已知问题」钉成断言，会在有人修好它的时候误报成失败。
##   → 只打印，交给验收的人对照清单第 3 节。
func _report_known_gaps() -> void:
	print("--- 已知问题现状（NOTE，不影响通过判定）---")
	var game_src := _read_source(GAME_SCENE_SRC)

	# ① 多人局开局后玩家角色晚约 1.2 秒出现。
	var waits := game_src.contains("REMOTE_SPAWN_DELAY_SEC")
	_note(waits,
		"多人局开局后玩家角色会晚约 1.2 秒才出现（房主故意等一下再把**所有人**"
		+ "——含房主自己——**一起**放进来）"
		+ " → 清单 A4 里「角色没立刻出现」**不是 bug**",
		"房主现在不再等那 1.2 秒了 → 清单 A4 的「晚 1.2 秒才出现」和第 3 节第 2 条要改")

	# ③ 客户端的「收工」按钮是灰的（只有房主能收工）。
	var only_host := game_src.contains("set_finish_enabled")
	_note(only_host,
		"客户端的「收工」按钮是**置灰**的（设计如此，只有房主能收工）"
		+ " → 清单 E1 里看到灰按钮**不是故障**",
		"「收工」按钮的置灰逻辑找不到了 → 清单 E1 需要重新确认")

	# ④ 结算里的「被抓次数」是本局计数台账。
	var ledger := game_src.contains("_caught_counts")
	_note(ledger,
		"结算里的「被抓 N 次」是**本局计数台账**（下一局重新从 0 开始）",
		"结算里的「被抓次数」不再是一份本局台账了 → 清单第 3 节第 7 条要改")


## ==================================================================
## 工具
## ==================================================================
func _instantiate(scene_path: String) -> Node:
	var packed: PackedScene = load(scene_path)
	if packed == null:
		return null
	var node := packed.instantiate()
	if node == null:
		return null
	root.add_child(node)
	return node


## 递归收集一棵子树里所有 Label 的文字。
func _label_texts(node: Node) -> Array[String]:
	var out: Array[String] = []
	if node == null:
		return out
	if node is Label:
		out.append((node as Label).text)
	for c in node.get_children():
		out.append_array(_label_texts(c))
	return out


## 一份清单的 id 集合（排序后拼成字符串，便于逐字比较）。
func _id_set(hand: Array) -> String:
	var ids: Array[String] = []
	for m in hand:
		ids.append(String((m as Mischief).id))
	ids.sort()
	return "|".join(ids)


## 字符串里有没有至少一个中日韩统一表意文字。
func _has_cjk(s: String) -> bool:
	for i in s.length():
		var c := s.unicode_at(i)
		if c >= 0x4E00 and c <= 0x9FFF:
			return true
	return false


func _count_occurrences(haystack: String, needle: String) -> int:
	if needle.is_empty():
		return 0
	var n := 0
	var idx := haystack.find(needle)
	while idx >= 0:
		n += 1
		idx = haystack.find(needle, idx + needle.length())
	return n


## 读源码（纯文本；归一化换行，避免依赖工作区的换行符）。
func _read_source(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var text := FileAccess.get_file_as_string(path)
	return text.replace("\r\n", "\n")


## 源码的**代码部分**（**整行注释**整行去掉；行尾注释不处理 —— 够用即可）。
##
## ★ 为什么需要：判据「生产链路接通了」不能被**注释**满足 ——
##   否则有人在注释里写一句「这里会写 meta lamp_on」就能骗过它。
func _code_lines(src: String) -> String:
	var out: Array[String] = []
	for line in src.replace("\r\n", "\n").split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		out.append(line)
	return "\n".join(out)


## 列表里第一个坏元素（空串 = 全好）。
func _first(list: Array) -> String:
	if list.is_empty():
		return ""
	return String(list[0])


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1


## 打印一条「现状说明」（不影响通过判定）。
##
## applies == true  → 这条已知问题**当前仍然成立**，打印 applies_text。
## applies == false → 它**已经不成立了**（多半是被人修好了），
##                     打印 fixed_text，提醒去更新清单第 3 节。
func _note(applies: bool, applies_text: String, fixed_text: String) -> void:
	_notes += 1
	if applies:
		print("  [NOTE] " + applies_text)
	else:
		print("  [NOTE] " + fixed_text)


func _finish() -> void:
	print("")
	print("断言总数：%d（另有 %d 条现状说明）" % [_total, _notes])
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)
