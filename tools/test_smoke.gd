extends SceneTree

## Task 12：P1 竖切片的**端到端冒烟测试**。
##
## ------------------------------------------------------------------
## 【它钉的是什么】
## P1 的验收目标是：
##   本地双窗口能一起开局 → 领捣蛋清单 → 执行捣蛋 → 被守卫抓到并送回出生点
##   （**进度不清零**）→ 天亮结算。
## → 下面按顺序覆盖这 **5 段**，每段都有断言。
##
## ------------------------------------------------------------------
## 【两段结构】
##   * **单进程段**：本机 ENet 服务端 + 1 个 peer → 跑 ②③④⑤ 的**房主侧**全流程。
##     ★ 必须先 `host_game()` + `apply_to_multiplayer()` → `.rpc()` 才走得通；
##       **不许**用「直接调 adjudicate()」绕过去（那正是 Task 10 钉死的检测力缺口）。
##   * **双进程段**：房主进程 + 客户端进程 → 跑 ① 的**跨端事实**、
##     缺口 C 的存在性证明、两端路径一致、两端结算对称。
##
## ------------------------------------------------------------------
## 【端口】
## 测试端口**动态分配**：候选池只有 27100–27299（tools/port_alloc.gd），
## **绑定成功**才算可用（真实 socket 裁决）。**不许硬编码任何 270xx**。
##
## ------------------------------------------------------------------
## 【子进程】
## 子脚本：res://tools/smoke_child.gd（**故意不叫 test_*.gd**，
## 否则会被统一入口当成独立测试单独跑）。
## 端口交接走**交接文件**（房主绑定成功后写端口号，父进程轮询它）
## —— 不用魔法延迟。

const PortAlloc := preload("res://tools/port_alloc.gd")
const SessionScript := preload("res://scripts/net/session.gd")

const CHILD_SCRIPT := "res://tools/smoke_child.gd"
const GAME_SCENE := "res://scenes/game.tscn"
const RESULT_SCENE := "res://scenes/result.tscn"
const LOBBY_SCENE := "res://scenes/lobby.tscn"
const HUD_SCENE := "res://scenes/ui/hud.tscn"
const LOBBY_UI_SRC := "res://scripts/ui/lobby_ui.gd"
const SESSION_SRC := "res://scripts/net/session.gd"
const RESULT_SRC := "res://scripts/ui/result_screen.gd"
const HUD_SRC := "res://scripts/ui/hud.gd"

## 惩罚性 token（零失败惩罚）。口径与 tools/test_session.gd 一致。
const PENALTY_TOKENS := ["penalty", "penalized", "score", "score_delta",
	"lives", "lives_lost", "eliminated", "damage", "扣分", "扣命", "淘汰", "死亡"]
const PENALTY_WORD_TOKENS := ["hp"]

## 子进程的兜底退出帧数（真正的退出靠子进程自己的 quit(0)）。
const CHILD_QUIT_AFTER := "20000"
## 房主子进程最多试多少个候选端口。
const HOST_CANDIDATES := 8
## 交接文件轮询：间隔（毫秒）与上限（毫秒）。
const HANDOFF_POLL_MS := 25
const HANDOFF_TIMEOUT_MS := 15000

## 轮询等待的间隔（秒）与上限（毫秒）。
const STEP_SEC := 0.05
const WAIT_TIMEOUT_MS := 20000
## 本测试的**帧预算**（统一入口用 --quit-after 600 跑）。
## 单进程段的等待都算在这里；双进程段是阻塞调用（不推进帧）。
const FRAME_BUDGET := 420

## 房主 peer id 恒为 1（ENet server-relay）。
const HOST_PEER_ID := 1

## 1 人局时每份清单的张数（clampi(player_count + 1, 3, 5) = 3）—— **写字面量**。
const EXPECT_HAND_SIZE_1P := 3
## 2 人局时每份清单的张数（clampi(2 + 1, 3, 5) = 3）—— **写字面量**。
const EXPECT_HAND_SIZE_2P := 3
## steal_carrot 的标题（data/mischief.json 里��字面量）。
const STEAL_CARROT_TITLE := "偷走杂货铺的萝卜"

var _fails := 0
var _total := 0

## 单进程段的信号计数（**成员变量**：GDScript 的 lambda 是**按值捕获**局部变量的）。
var _sp_round_started := 0
var _sp_round_ended := 0
var _sp_summary: Dictionary = {}


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await _source_part()
	await _single_process_part()
	await _lobby_fake_session_part()
	await _double_process_part()
	_finish()


## ==================================================================
## 静态 / 源码段：缺口 A / B / D 的「接线」确实在文件里
## ==================================================================
func _source_part() -> void:
	print("=== 静态与源码断言段（缺口 A / B / D 的接线）===")
	var lobby_src := _read_source(LOBBY_UI_SRC)
	var session_src := _read_source(SESSION_SRC)
	var result_src := _read_source(RESULT_SRC)
	var hud_src := _read_source(HUD_SRC)

	# ------------------------------------------------------------------
	# 缺口 A：客户端切场景（由 round_started 驱动，两端对称）
	# ------------------------------------------------------------------
	_fails += _check(lobby_src.contains("round_started.connect("),
		"[G1] lobby_ui.gd 连上了 Session.round_started")
	_fails += _check(lobby_src.contains("router.goto(game_scene_path)"),
		"[G2] lobby_ui.gd 的切场景用的是 game_scene_path 变量（不是常量 GAME_SCENE）")
	var on_round := _func_body(lobby_src, "func _on_round_started")
	_fails += _check(on_round.contains("router.goto(game_scene_path)"),
		"[G3] _on_round_started 里确实切场景（用的是 game_scene_path）")
	_fails += _check(not on_round.contains("GAME_SCENE"),
		"[G4] _on_round_started 里没有用常量 GAME_SCENE")
	var on_start := _func_body(lobby_src, "func _on_start")
	_fails += _check(not on_start.contains("router.goto("),
		"[G5] _on_start 里没有残留直接的 router.goto(（否则房主切两次场景）")
	_fails += _check(on_start.contains("ResourceLoader.exists(game_scene_path)"),
		"[G6] _on_start 的场景存在性守卫还在")
	_fails += _check(on_start.find("ResourceLoader.exists(game_scene_path)") >= 0
			and on_start.find("ResourceLoader.exists(game_scene_path)")
				< on_start.find("start_round()"),
		"[G7] 存在性守卫仍然在 start_round() 之前（场景缺失时不开回合）")

	# ------------------------------------------------------------------
	# 缺口 B：端口
	# ------------------------------------------------------------------
	var default_port := -1
	var session_script: GDScript = load(SESSION_SRC) as GDScript
	if session_script != null:
		var cmap: Dictionary = session_script.get_script_constant_map()
		default_port = int(cmap.get("DEFAULT_PORT", -1))
	_fails += _check(default_port == 28000,
		"[G8] Session.DEFAULT_PORT == 28000（实际 %d）" % default_port)
	_fails += _check(not PortAlloc.reserved().has(28000),
		"[G9] 28000 不在 PortAlloc.reserved() 里（不与历史保留端口冲突）")
	_fails += _check(not PortAlloc.candidates().has(28000),
		"[G10] 28000 不在 PortAlloc.candidates() 里（不与测试候选池冲突）")
	_fails += _check(session_src.contains("func host_game(port: int = DEFAULT_PORT) -> Error:"),
		"[G11] host_game 的签名未变")
	_fails += _check(session_src.contains(
			"func join_game(address: String, port: int = DEFAULT_PORT) -> Error:"),
		"[G12] join_game 的签名未变")

	# ------------------------------------------------------------------
	# 缺口 D：结算有触发入口（HUD 上的「收工」按钮）
	# ------------------------------------------------------------------
	var hud_packed: PackedScene = load(HUD_SCENE)
	var hud_inst: Node = null
	if hud_packed != null:
		hud_inst = hud_packed.instantiate()
	_fails += _check(hud_inst != null and hud_inst.get_node_or_null("FinishButton") != null,
		"[G13] hud.tscn 上有「收工」按钮节点")
	_fails += _check(hud_src.contains("$FinishButton"),
		"[G14] hud.gd 里有对应的 @onready 声明（场景与脚本逐字对应）")
	_fails += _check(hud_src.contains("finish_pressed"),
		"[G15] hud.gd 把「收工」接成了信号（对局场景接它）")
	_fails += _check(game_scene_src_has_finish_hook(),
		"[G16] game_scene.gd 接了「收工」并调 end_round(summary)")
	if hud_inst != null:
		hud_inst.free()

	# ------------------------------------------------------------------
	# 结算页：场景 / 脚本路径对应 + 纯净化
	# ------------------------------------------------------------------
	var result_packed: PackedScene = load(RESULT_SCENE)
	_fails += _check(result_packed != null, "[G17] result.tscn 可加载")
	var result_inst: Node = null
	if result_packed != null:
		result_inst = result_packed.instantiate()
	_fails += _check(result_inst != null
			and result_inst.get_node_or_null("Center/Panel/Margin/HBox") != null,
		"[G18] result.tscn 含 Center/Panel/Margin/HBox")
	_fails += _check(result_src.contains("$Center/Panel/Margin/HBox"),
		"[G19] result_screen.gd 的 @onready 路径与场景逐字一致")
	_fails += _check(result_src.contains("func show_summary(summary: Dictionary) -> void:"),
		"[G20] result_screen.gd 有 show_summary(summary) 接口")
	_fails += _check(not result_src.contains("Steam."),
		"[G21] result_screen.gd 不出现 Steam. 调用")
	for token in PENALTY_TOKENS:
		_fails += _check(not result_src.contains(token),
			"[G22] result_screen.gd 不出现惩罚性 token「%s」（零失败惩罚）" % token)
	for token in PENALTY_WORD_TOKENS:
		_fails += _check(not _has_word(result_src, token),
			"[G23] result_screen.gd 不出现惩罚性 token「%s」（独立词）" % token)
	_fails += _check(not result_src.contains("排行榜") and not result_src.contains("成就"),
		"[G24] result_screen.gd 不出现名次 / 成就类展示（只有信息陈列）")
	if result_inst != null:
		result_inst.free()


## ==================================================================
## 单进程段：房主侧全流程 ②③④⑤
## ==================================================================
func _single_process_part() -> void:
	print("")
	print("=== 单进程段（②③④⑤ 房主侧全流程）===")
	var session = root.get_node_or_null("Session")
	_fails += _check(session != null, "[S1] Session 自动加载存在（生产用的 /root/Session）")
	if session == null:
		return

	# ★ 真的 ENet 服务端 → .rpc() 走得通（不许绕开生产入口）。
	var port := _host_on(session)
	_fails += _check(port > 0,
		"[S2] 本机 ENet 服务端绑定成功（动态端口 %d，候选池 27100–27299）" % port)
	_fails += _check(session.is_host(), "[S3] Session 是房主")

	# 进大厅（生产路径）。
	change_scene_to_file(LOBBY_SCENE)
	await _wait_ms(400)
	var lobby = current_scene
	_fails += _check(lobby != null, "[S4] 大厅场景装载成功")
	if lobby == null:
		return
	var lobby_path := str(lobby.get("game_scene_path"))
	_fails += _check(lobby_path == "res://scenes/game.tscn",
		"[S5] 大厅读到的对局场景路径 == res://scenes/game.tscn（实际 '%s'）" % lobby_path)

	session.round_started.connect(_on_sp_round_started)
	session.round_ended.connect(_on_sp_round_ended)

	# 房主点「开始这一夜」。
	lobby.call(&"_on_start")
	var in_game := await _wait_until(WAIT_TIMEOUT_MS, func() -> bool:
		return _current_scene_file() == GAME_SCENE)
	_fails += _check(_sp_round_started == 1,
		"[S6] 点「开始」触发了 round_started（实际 %d 次）" % _sp_round_started)
	_fails += _check(in_game,
		"[S7] 缺口 A（房主侧）：round_started 后切进对局场景（实际 '%s'）"
		% _current_scene_file())
	if not in_game:
		return

	var game = current_scene
	var players = game.get_node_or_null("Players")
	var rpc_node = game.get_node_or_null("RPC")
	_fails += _check(players != null, "[S8] 对局场景里有 Players 容器")
	_fails += _check(rpc_node != null, "[S9] 对局场景里有 RPC 节点")

	# ------------------------------------------------------------------
	# ② 领捣蛋清单
	# ------------------------------------------------------------------
	var deal: Array = session.deal()
	_fails += _check(deal.size() == 1,
		"[S10] 房主拿到 1 份清单（实际 %d 份）" % deal.size())
	var hand: Array = deal[0] if deal.size() > 0 else []
	_fails += _check(hand.size() == EXPECT_HAND_SIZE_1P,
		"[S11] 1 人局的清单是 %d 张（clampi(1+1,3,5)，实际 %d 张）"
		% [EXPECT_HAND_SIZE_1P, hand.size()])
	var fields_ok := true
	for m in hand:
		if str(m.get("id")) == "" or str(m.get("title")) == "":
			fields_ok = false
		if str(m.get("category")) == "" or str(m.get("target_tag")) == "":
			fields_ok = false
		if typeof(m.get("needs_partner")) != TYPE_BOOL:
			fields_ok = false
		if float(m.get("duration")) <= 0.0 or int(m.get("points")) < 0:
			fields_ok = false
	_fails += _check(fields_ok, "[S12] 清单里每张牌都是 Mischief 对象且 7 个字段可读")

	var local = players.get_node_or_null(str(HOST_PEER_ID)) if players != null else null
	_fails += _check(local != null,
		"[S13] 房主的本地玩家节点存在（节点名 == 本地 peer id 1）")
	if local == null:
		return
	var local_hand: Array = local.get("hand")
	_fails += _check(local_hand.size() == EXPECT_HAND_SIZE_1P,
		"[S14] 本地玩家的手牌是自己那一份（%d 张，实际 %d）"
		% [EXPECT_HAND_SIZE_1P, local_hand.size()])
	var own_hand: Array = session.deal_for_peer(HOST_PEER_ID)
	_fails += _check(own_hand.size() == EXPECT_HAND_SIZE_1P
			and local_hand.size() == own_hand.size(),
		"[S15] 本地玩家的手牌张数 == deal_for_peer(本地 peer id) 的张数")

	# ------------------------------------------------------------------
	# ③ 执行捣蛋（走**生产入口** send_submit_mischief）
	# ------------------------------------------------------------------
	# 先把「手上有一条进行中的捣蛋」摆好（进度由操作方累积）。
	local.set("current_behavior_id", &"steal_carrot")
	local.set("current_mischief_progress", 0.5)
	local.set("current_target_id", 1)
	rpc_node.call(&"send_submit_mischief", "steal_carrot", 1)
	await _wait_ms(200)
	var payload: Dictionary = rpc_node.get("last_mischief_payload")
	_fails += _check(payload.size() == 4,
		"[S16] 结算载荷恰好 4 个字段（实际 %d 个）" % payload.size())
	_fails += _check(str(payload.get("behavior_id", "")) != "",
		"[S17] 载荷的 behavior_id 非空（实际 '%s'）" % str(payload.get("behavior_id", "")))
	_fails += _check(int(payload.get("peer_id", -1)) == HOST_PEER_ID,
		"[S18] 载荷的 peer_id == 提交方（实际 %d）" % int(payload.get("peer_id", -1)))
	_fails += _check(bool(payload.get("success", false)),
		"[S19] 裁决成功（reason '%s'）" % str(payload.get("reason", "")))
	_fails += _check(int(local.get("completed_mischief")) == 1,
		"[S20] 成功后该行为的已完成次数 +1（实际 %d）"
		% int(local.get("completed_mischief")))

	# ------------------------------------------------------------------
	# ④ 被抓 → 押送 → 送回**自己的**出生点
	# ------------------------------------------------------------------
	var guards = game.get_node_or_null("Guards")
	var guard: Node = null
	if guards != null and guards.get_child_count() > 0:
		guard = guards.get_child(0)
	_fails += _check(guard != null, "[S21] 房主侧有守卫节点")
	if guard == null:
		return
	var brain = guard.get("brain")
	# 把守卫挪离岗位一点：这样 RETURN 状态能观察到（它走回岗位需要时间）。
	guard.position = Vector2(480 + 90, 288)
	# ★ 把玩家挪离**自己的出生点**：否则它一进押送状态就「已经到家」，
	#   下一帧立刻结束押送 → 观察不到「被押送」这个中间态。
	local.position = Vector2(local.get("spawn_position")) + Vector2(60, 0)
	brain.set("target_peer", HOST_PEER_ID)
	brain.call(&"begin_carry")
	# 房主广播「被抓」（生产入口）。
	rpc_node.call(&"broadcast_player_caught", HOST_PEER_ID, 1)
	await _wait_ms(150)
	_fails += _check(bool(local.get("escorted")),
		"[S22] 被抓后玩家进入被押送状态")
	_fails += _check(is_equal_approx(float(local.get("current_mischief_progress")), 0.0),
		"[S23] 被抓 → 手上那一条的**进行中进度作废**（回 0）")
	_fails += _check(int(local.get("completed_mischief")) == 1,
		"[S24] 被抓**不清零**已完成次数（仍是 1，实际 %d）"
		% int(local.get("completed_mischief")))

	# 玩家自己走回**自己的**出生点 → 押送结束 → 房主 finish_carry()。
	local.position = local.get("spawn_position")
	var returned := await _wait_until(3000, func() -> bool:
		return not bool(local.get("escorted")))
	_fails += _check(returned, "[S25] 玩家自己走回自己的出生点 → 押送结束")
	var saw_return := await _wait_until(1500, func() -> bool:
		return int(brain.get("state")) == 4)
	_fails += _check(saw_return,
		"[S26] 房主侧 finish_carry() → RETURN（守卫状态实际 %d，4 = RETURN）"
		% int(brain.get("state")))
	var back_patrol := await _wait_until(4000, func() -> bool:
		return int(brain.get("state")) == 0)
	_fails += _check(back_patrol,
		"[S27] 守卫走回岗位 → 回到 PATROL（实际状态 %d）" % int(brain.get("state")))
	_fails += _check(is_equal_approx(float(brain.get("suspicion")), 0.0),
		"[S28] 押送结束后怀疑度清零")

	# ------------------------------------------------------------------
	# ⑤ 天亮结算（只有房主能点「收工」）
	# ------------------------------------------------------------------
	var hud = game.get_node_or_null("HUD")
	var finish_btn = hud.get_node_or_null("FinishButton") if hud != null else null
	_fails += _check(finish_btn != null, "[S29] HUD 上有「收工」按钮")
	_fails += _check(finish_btn != null and not bool(finish_btn.get("disabled")),
		"[S30] 房主侧的「收工」按钮可点（disabled == false）")
	if finish_btn == null:
		return
	finish_btn.emit_signal(&"pressed")
	await _wait_ms(400)
	_fails += _check(_sp_round_ended == 1,
		"[S31] 点「收工」触发 round_ended（实际 %d 次）" % _sp_round_ended)
	_fails += _check(session.deal().is_empty(),
		"[S32] end_round 之后 Session.deal() 为空")
	var summary := _sp_summary
	_fails += _check(summary.size() == 1,
		"[S33] 结算载荷里每个 peer 一项（实际 %d 项）" % summary.size())
	var info: Dictionary = summary.get(1, {}) if summary.has(1) else {}
	_fails += _check(_sorted_keys(info) == ["caught", "done", "mischief_titles", "name"],
		"[S34] 摘要项的字段齐全（name / done / caught / mischief_titles），实际 %s"
		% str(_sorted_keys(info)))
	_fails += _check(int(info.get("done", -1)) == 1,
		"[S35] 摘要的 done == 1（实际 %d）" % int(info.get("done", -1)))
	_fails += _check(int(info.get("caught", -1)) == 1,
		"[S36] 摘要的 caught == 1（实际 %d）" % int(info.get("caught", -1)))
	var titles: Array = info.get("mischief_titles", [])
	_fails += _check(titles.size() == 1 and str(titles[0]) == STEAL_CARROT_TITLE,
		"[S37] 摘要的捣蛋标题 == 「%s」（实际 %s）"
		% [STEAL_CARROT_TITLE, str(titles)])
	_fails += _check(_is_pure_data(summary),
		"[S38] 结算载荷是**纯数据**（没有 Object / Resource / Callable）")
	_fails += _check(str(info.get("name", "")) == "玩家 1",
		"[S39] 摘要的 name 两端一致（房主组装并广播，实际 '%s'）"
		% str(info.get("name", "")))

	# 结算页渲染。
	var at_result := await _wait_until(5000, func() -> bool:
		return _current_scene_file() == RESULT_SCENE)
	_fails += _check(at_result,
		"[S40] 收工后切到结算页（实际 '%s'）" % _current_scene_file())
	var result = current_scene
	var cards = result.get_node_or_null("Center/Panel/Margin/HBox") if result != null else null
	_fails += _check(cards != null and cards.get_child_count() == 1,
		"[S41] 结算页每位玩家一张卡片（实际 %d 张）"
		% (cards.get_child_count() if cards != null else -1))
	var card_text := _all_text(cards) if cards != null else ""
	_fails += _check(card_text.contains("玩家 1"),
		"[S42] 卡片上显示玩家名")
	_fails += _check(card_text.contains("捣蛋 1 次"),
		"[S43] 卡片上显示已完成次数")
	_fails += _check(card_text.contains("被抓 1 次"),
		"[S44] 卡片上显示被抓次数")
	_fails += _check(card_text.contains(STEAL_CARROT_TITLE),
		"[S45] 卡片上显示捣蛋标题")
	# 再调一次 show_summary → 不残留旧卡片。
	# ★ 先确认当前场景**真的是**结算页再调（失败路径上它可能还是对局场景
	#   → 对着错的节点调方法会打一条 SCRIPT ERROR，把「失败的干净程度」毁掉）。
	if result != null and result.has_method(&"show_summary"):
		result.call(&"show_summary", summary)
		await process_frame
	_fails += _check(result != null and result.has_method(&"show_summary")
			and cards != null and cards.get_child_count() == 1,
		"[S46] show_summary() 调用两次不残留旧卡片（实际 %d 张）"
		% (cards.get_child_count() if cards != null else -1))

	# 收尾：把本进程占着的端口放掉（双进程段要用候选池里的端口）。
	session.call(&"_drop_transport")


## ==================================================================
## 缺口 A 的**行为层**：替身 Session 发出的 round_started → 大厅请求切场景
## ==================================================================
##
## ★ 这一段专门模拟「测试事后注入替身 Session」这个模式
##   （tools/test_session.gd:527-543 就是这个模式）：
##   大厅的 _ready() 先连上 **autoload**，之后 `_session` 被换成替身
##   → 连接必须**跟着换**，否则替身发信号时大厅收不到。
## ★ 期望值：大厅**确实请求了**切场景 → 当前场景变成对局场景。
func _lobby_fake_session_part() -> void:
	print("")
	print("=== 缺口 A 行为层（替身 Session → 大厅请求切场景）===")
	var lobby_packed: PackedScene = load(LOBBY_SCENE)
	if lobby_packed == null:
		_fails += _check(false, "[B0] lobby.tscn 可加载")
		return
	var lobby2: Node = lobby_packed.instantiate()
	root.add_child(lobby2)
	await process_frame
	_fails += _check(lobby2.get("_session") != null,
		"[B1] 大厅的 _ready() 拿到了 autoload 的 Session")
	# ★ 先把**当前场景**摆成大厅 → 「切到对局场景」才是一个**可观察的状态转移**
	#   （否则上一段留下的当前场景可能就是对局场景，断言会白通过）。
	change_scene_to_file(LOBBY_SCENE)
	await _wait_ms(300)
	_fails += _check(_current_scene_file() == LOBBY_SCENE,
		"[B1b] 当前场景已摆成大厅（实际 '%s'）" % _current_scene_file())

	# 替身 Session：真的开一个房（房主才能 start_round）。
	var fake = SessionScript.new()
	fake.name = "FakeSession"
	root.add_child(fake)
	fake.set_transport(ENetTransport.new())
	var fake_port := _host_on(fake)
	_fails += _check(fake_port > 0,
		"[B2] 替身 Session 建房成功（端口 %d）" % fake_port)
	# ★ 事后替换（这正是「连接会变陈旧」的场景）。
	lobby2.set("_session", fake)
	_fails += _check(lobby2.get("_session") == fake,
		"[B3] 大厅的 _session 已换成替身 Session")

	# 替身发信号 → 大厅必须切场景。
	lobby2.call(&"_on_start")
	var switched := await _wait_until(5000, func() -> bool:
		return _current_scene_file() == GAME_SCENE)
	_fails += _check(switched,
		"[B4] ★缺口A（行为层）：替身 Session 的 round_started → 大厅**确实请求了**切场景（当前场景 '%s'）"
		% _current_scene_file())

	fake.call(&"_drop_transport")
	lobby2.queue_free()
	await process_frame


## ==================================================================
## 双进程段：① 一起开局 + 缺口 C + 两端路径一致 + ⑤ 两端对称
## ==================================================================
func _double_process_part() -> void:
	print("")
	print("=== 双进程段（① 一起开局 + 缺口 C + 两端对称）===")
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var handoff := "user://smoke_handoff_%s.txt" % _rand_hex()
	_fails += _check(not FileAccess.file_exists(handoff),
		"[D0] 交接文件在开跑前不存在（不会读到上一次运行的残留）")

	var win := PortAlloc.window(HOST_CANDIDATES)
	var base_port: int = win[0]
	var span: int = win.size()
	var host_args := _child_args(proj, "host", base_port, span, handoff)
	var host_out: Array = []
	var th := Thread.new()
	th.start(func() -> void: OS.execute(exe, host_args, host_out, true))

	# 等房主把端口占上（轮询交接文件，不用魔法延迟）。
	var host_port := -1
	var deadline := Time.get_ticks_msec() + HANDOFF_TIMEOUT_MS
	while Time.get_ticks_msec() < deadline:
		host_port = _read_handoff_port(handoff)
		if host_port > 0:
			break
		if not th.is_alive():
			break
		OS.delay_msec(HANDOFF_POLL_MS)
	_fails += _check(host_port > 0,
		"[D1] 从交接文件拿到了房主实际占用的端口（实际 %d）" % host_port)

	# 客户端子进程：前台阻塞跑。
	var client_args := _child_args(proj, "client", host_port, 1, "-")
	var client_out: Array = []
	var client_code := OS.execute(exe, client_args, client_out, true)
	th.wait_to_finish()

	var host := _parse(host_out)
	var client := _parse(client_out)

	_fails += _check(host.has("DONE"), "[D2] 房主子进程正常跑完并回报")
	_fails += _check(client.has("DONE"), "[D3] 客户端子进程正常跑完并回报")
	_fails += _check(client_code == 0,
		"[D4] 客户端子进程退出码为 0（实际 %d）" % client_code)
	_fails += _check(host.get("host_err", "") == "0",
		"[D5] 房主建房成功（err=%s）" % str(host.get("host_err", "")))
	_fails += _check(client.get("join_err", "") == "0",
		"[D6] 客户端加入成功（err=%s）" % str(client.get("join_err", "")))
	_fails += _check(host.get("is_host", "") == "1", "[D7] 房主是房主")
	_fails += _check(client.get("is_host", "") == "0", "[D8] 客户端不是房主")

	# ------------------------------------------------------------------
	# ① 一起开局
	# ------------------------------------------------------------------
	_fails += _check(host.get("peer_count", "") == "2",
		"[D9] 房主侧看到 2 人（实际 %s）" % str(host.get("peer_count", "")))
	_fails += _check(client.get("peer_count", "") == "2",
		"[D10] 客户端收到了房主名单（peer_count=2，实际 %s）"
		% str(client.get("peer_count", "")))
	_fails += _check(host.get("roster", "") == client.get("roster", "") and
			not str(host.get("roster", "")).is_empty(),
		"[D11] 两端名单一致：房主 %s / 客户端 %s"
		% [str(host.get("roster", "")), str(client.get("roster", ""))])
	_fails += _check(host.get("round_started", "") == "1",
		"[D12] 房主触发了 round_started（实际 %s 次）" % str(host.get("round_started", "")))
	_fails += _check(client.get("round_started", "") == "1",
		"[D13] 客户端也触发了 round_started（实际 %s 次）"
		% str(client.get("round_started", "")))
	_fails += _check(host.get("deal_hands", "") == "2",
		"[D14] 房主手里是 2 份清单（每个 peer 一份，实际 %s 份）"
		% str(host.get("deal_hands", "")))
	_fails += _check(client.get("deal_hands", "") == "1",
		"[D15] 客户端只拿到自己那 1 份（实际 %s 份）" % str(host.get("deal_hands", "")))
	_fails += _check(_count_ids(host.get("card_ids", "")) == EXPECT_HAND_SIZE_2P,
		"[D16] 客户端那一份是 %d 张（实际 %d 张）"
		% [EXPECT_HAND_SIZE_2P, _count_ids(client.get("card_ids", ""))])
	_fails += _check(_count_ids(host.get("card_ids", "")) == EXPECT_HAND_SIZE_2P,
		"[D17] 房主自己那一份也是 %d 张（实际 %d 张）"
		% [EXPECT_HAND_SIZE_2P, _count_ids(host.get("card_ids", ""))])
	_fails += _check(client.get("card_ids", "") != host.get("card_ids", ""),
		"[D18] 两端拿到的是**不同**的那一份（没有互相泄漏）")

	# ------------------------------------------------------------------
	# 缺口 C：客户端必须真的拿到自己的玩家节点
	# ------------------------------------------------------------------
	_fails += _check(client.get("local_player_found", "") == "1",
		"[D19] ★缺口C：客户端的 Players 里有节点名 == 本地 peer id 的玩家节点")
	_fails += _check(int(client.get("local_hand_size", "0")) == EXPECT_HAND_SIZE_2P,
		"[D20] ★缺口C：客户端那个节点的 hand 非空（%d 张，实际 %d 张）"
		% [EXPECT_HAND_SIZE_2P, int(client.get("local_hand_size", "0"))])
	_fails += _check(int(client.get("local_hand_size", "0")) == _count_ids(client.get("card_ids", ""))
			and int(client.get("local_hand_size", "0")) > 0,
		"[D21] ★缺口C：客户端节点的 hand 张数 == 客户端 deal()[0] 的张数（%d vs %d）"
		% [int(client.get("local_hand_size", "0")), _count_ids(client.get("card_ids", ""))])
	_fails += _check(_has_name(host.get("player_names", ""), "1"),
		"[D22] ★缺口C：房主侧存在节点名 == 房主 peer id（1）的节点（实际 '%s'）"
		% str(host.get("player_names", "")))
	_fails += _check(int(host.get("player_count", "0")) == int(host.get("peer_count", "0")),
		"[D23] ★缺口C：房主的 Players 里有几个人 == 两端 peer_count（%s / %s）"
		% [str(host.get("player_count", "")), str(host.get("peer_count", ""))])
	_fails += _check(int(client.get("player_count", "0")) == 2,
		"[D24] ★缺口C：客户端的 Players 里也有 2 个节点（实际 %s）"
		% str(client.get("player_count", "")))

	# ------------------------------------------------------------------
	# 两端路径一致（Task 11 复审 M-3 的缺口）
	# ------------------------------------------------------------------
	var host_path := str(host.get("lobby_scene_path", ""))
	var client_path := str(client.get("lobby_scene_path", ""))
	_fails += _check(not host_path.is_empty() and host_path == client_path,
		"[D25] 两端各自读出的对局场景路径**逐字节相等**（房主 '%s' / 客户端 '%s'）"
		% [host_path, client_path])
	_fails += _check(host_path == "res://scenes/game.tscn"
			and client_path == "res://scenes/game.tscn",
		"[D26] 两端路径都 == res://scenes/game.tscn（实际 '%s' / '%s'）"
		% [host_path, client_path])
	_fails += _check(host.get("game_scene_file", "") == "res://scenes/game.tscn",
		"[D27] 房主真的切进了对局场景（current_scene '%s'）"
		% str(host.get("game_scene_file", "")))
	_fails += _check(client.get("game_scene_file", "") == "res://scenes/game.tscn",
		"[D28] ★缺口A：客户端也真的切进了对局场景（current_scene '%s'）"
		% str(client.get("game_scene_file", "")))

	# ------------------------------------------------------------------
	# 缺口 D：只有房主能收工；两端对称切到结算页
	# ------------------------------------------------------------------
	_fails += _check(host.get("finish_disabled", "") == "0",
		"[D29] 房主侧的「收工」按钮可点（disabled == false）")
	_fails += _check(client.get("finish_disabled", "") == "1",
		"[D30] ★缺口D：客户端的「收工」按钮置灰（disabled == true）")
	_fails += _check(host.get("round_ended", "") == "1",
		"[D31] 房主侧触发了 round_ended（实际 %s 次）" % str(host.get("round_ended", "")))
	_fails += _check(client.get("round_ended", "") == "1",
		"[D32] ★缺口D：客户端也触发了 round_ended（实际 %s 次）"
		% str(client.get("round_ended", "")))
	_fails += _check(host.get("result_scene_file", "") == "res://scenes/result.tscn",
		"[D33] 房主切到了结算页（current_scene '%s'）"
		% str(host.get("result_scene_file", "")))
	_fails += _check(client.get("result_scene_file", "") == "res://scenes/result.tscn",
		"[D34] ★缺口D：客户端也切到了结算页（current_scene '%s'）"
		% str(client.get("result_scene_file", "")))
	_fails += _check(int(host.get("result_cards", "0")) == 2,
		"[D35] 房主的结算页每人一张卡片（实际 %s 张）" % str(host.get("result_cards", "")))
	_fails += _check(int(client.get("result_cards", "0")) == 2,
		"[D36] 客户端的结算页每人一张卡片（实际 %s 张）"
		% str(client.get("result_cards", "")))
	_fails += _check(int(host.get("summary_players", "0")) == 2,
		"[D37] 房主侧摘要里每个 peer 一项（实际 %s 项）"
		% str(host.get("summary_players", "")))
	_fails += _check(int(client.get("summary_players", "0")) == 2,
		"[D38] 客户端侧摘要里每个 peer 一项（实际 %s 项）"
		% str(client.get("summary_players", "")))
	_fails += _check(host.get("summary_pure", "") == "1"
			and client.get("summary_pure", "") == "1",
		"[D39] 两端的结算载荷都是**纯数据**（能跨进程传）")
	_fails += _check(host.get("summary_fields", "")
			== "caught,done,mischief_titles,name",
		"[D40] 摘要项的字段齐全（实际 '%s'）" % str(host.get("summary_fields", "")))
	_fails += _check(host.get("summary_titles", "") == client.get("summary_titles", ""),
		"[D41] 两端显示的捣蛋标题一致（房主 '%s' / 客户端 '%s'）"
		% [str(host.get("summary_titles", "")), str(client.get("summary_titles", ""))])
	_fails += _check(host.get("summary_name", "") == client.get("summary_name", "")
			and not str(host.get("summary_name", "")).is_empty(),
		"[D42] 两端显示的玩家名一致（'%s'）" % str(host.get("summary_name", "")))

	# 真实链路全程没报错。
	_fails += _check(not _has_engine_noise(host_out),
		"[D43] 房主子进程输出里没有 ERROR / WARNING 行")
	_fails += _check(not _has_engine_noise(client_out),
		"[D44] 客户端子进程输出里没有 ERROR / WARNING 行")
	_fails += _check(int(host.get("exit_epoch_ms", "0")) > int(client.get("epoch_ms", "0")),
		"[D45] 房主的退出时刻晚于客户端的回报时刻（房主 %s / 客户端 %s，epoch 毫秒）——房主先退会把客户端掐断"
		% [str(host.get("exit_epoch_ms", "")), str(client.get("epoch_ms", ""))])

	_remove_own_handoff(handoff)
	if _fails > 0:
		print("---- 房主子进程输出 ----")
		for line in host_out:
			print("  H| " + str(line))
		print("---- 客户端子进程输出 ----")
		for line in client_out:
			print("  C| " + str(line))


## ==================================================================
## 工具
## ==================================================================

## 房主在本进程里开一个真的 ENet 服务端（动态端口，真实绑定裁决）。
func _host_on(session) -> int:
	var alloc := PortAlloc.new()
	while not alloc.exhausted():
		var p: int = alloc.next()
		if p < 0:
			break
		Engine.print_error_messages = false
		var err: Error = session.host_game(p)
		Engine.print_error_messages = true
		if err != OK:
			continue
		session.apply_to_multiplayer()
		return p
	return -1


func _child_args(proj: String, mode: String, base: int, span: int, handoff: String) -> PackedStringArray:
	return PackedStringArray([
		"--headless",
		"--path", proj,
		"--quit-after", CHILD_QUIT_AFTER,
		"--script", CHILD_SCRIPT,
		"--", mode, str(base), str(span), handoff,
	])


## 读交接文件里的端口号（失败一律 -1，绝不「静默当成 0 端口」）。
func _read_handoff_port(path: String) -> int:
	if path == "" or path == "-":
		return -1
	if not FileAccess.file_exists(path):
		return -1
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var txt := f.get_as_text().strip_edges()
	f.close()
	if txt.length() < 1 or txt.length() > 5:
		return -1
	if not txt.is_valid_int():
		return -1
	var p := txt.to_int()
	if p <= 0 or p > 65535:
		return -1
	return p


func _remove_own_handoff(path: String) -> void:
	if path == "" or path == "-":
		return
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return
	DirAccess.remove_absolute(abs_path)


## 解析子进程输出里的 `SMOKE|key=value` 行（**必须按换行拆开**）。
func _parse(out: Array) -> Dictionary:
	var d: Dictionary = {}
	for chunk in out:
		for raw in str(chunk).split("\n"):
			var line := raw.strip_edges()
			if not line.begins_with("SMOKE|"):
				continue
			var body := line.substr(6)
			var eq := body.find("=")
			if eq < 0:
				d[body] = "1"
			else:
				d[body.substr(0, eq)] = body.substr(eq + 1)
	return d


## 子进程输出里**有没有**引擎报错/告警行。
##
## ★ 用 `contains` 而不是 `begins_with`：引擎还有 `USER ERROR:` / `SCRIPT ERROR:`
##   等其它前缀，`begins_with("ERROR")` 会漏检它们。
func _has_engine_noise(out: Array) -> bool:
	for chunk in out:
		for raw in str(chunk).split("\n"):
			var line := raw.strip_edges()
			if line.contains("ERROR:") or line.contains("WARNING:"):
				return true
	return false


func _count_ids(ids: String) -> int:
	if ids.is_empty():
		return 0
	var parts := ids.split(",")
	var n := 0
	for p in parts:
		if not p.strip_edges().is_empty():
			n += 1
	return n


func _has_name(names: String, name: String) -> bool:
	for p in names.split(","):
		if p.strip_edges() == name:
			return true
	return false


func _sorted_keys(d: Dictionary) -> Array:
	var out: Array = d.keys()
	out.sort()
	return out


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
	return true


## 节点子树里所有 Label 的文字拼起来。
func _all_text(node: Node) -> String:
	var parts: Array[String] = []
	if node == null:
		return ""
	if node is Label:
		parts.append(str((node as Label).text))
	for c in node.get_children():
		parts.append(_all_text(c))
	return "|".join(parts)


func _current_scene_file() -> String:
	var cs = current_scene
	if cs == null:
		return ""
	return str(cs.scene_file_path)


func _wait_ms(ms: int) -> void:
	await create_timer(float(ms) / 1000.0).timeout


## 等一个条件成立（成立就立刻返回，不白等）。
##
## ★ **帧预算护栏**：统一入口用 `--quit-after 600` 跑本测试。
##   条件一直不成立时，光等就会把帧数用光 → 进程被引擎**静默掐掉**
##   （退出码 0、没有 "TEST FAILED" —— 那正是「看起来像没被抓住」的假象）。
##   → 帧数超线就**立刻判失败**返回，让测试正常走到结尾、明确报红。
func _wait_until(timeout_ms: int, cond: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if bool(cond.call()):
			return true
		if Engine.get_process_frames() > FRAME_BUDGET:
			print("  [WARN] 帧预算用尽（已用 %d 帧 / 预算 %d）→ 提前判失败"
				% [Engine.get_process_frames(), FRAME_BUDGET])
			return false
		await create_timer(STEP_SEC).timeout
	return bool(cond.call())


func _rand_hex() -> String:
	return "%08x%08x%08x" % [randi(), randi(), randi()]


## 读源码（纯文本；**归一化换行**，避免依赖工作区的换行符）。
func _read_source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text().replace("\r\n", "\n").replace("\r", "\n")


## 取某个函数的正文（从 `func xxx` 那行到下一个顶层 `func ` 之前）。
func _func_body(src: String, header: String) -> String:
	var out: Array[String] = []
	var inside := false
	for line in src.split("\n"):
		if line.begins_with(header):
			inside = true
			out.append(line)
			continue
		if inside:
			if line.begins_with("func "):
				break
			out.append(line)
	return "\n".join(out)


## game_scene.gd 里是不是真的接了「收工」→ end_round(summary)。
func game_scene_src_has_finish_hook() -> bool:
	var src := _read_source("res://scripts/game_scene.gd")
	return src.contains("finish_pressed") and src.contains("end_round")


## 源码里有没有出现「作为一个独立词」的 token（词边界匹配）。
func _has_word(src: String, token: String) -> bool:
	var re := RegEx.new()
	if re.compile("\\b%s\\b" % token) != OK:
		return src.contains(token)
	return re.search(src) != null


func _on_sp_round_started(_deal: Array) -> void:
	_sp_round_started += 1


func _on_sp_round_ended(summary: Dictionary) -> void:
	_sp_round_ended += 1
	_sp_summary = summary.duplicate(true)


func _finish() -> void:
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


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
