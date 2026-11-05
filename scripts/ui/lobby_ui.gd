extends Control

## 大厅界面：显示成员列表、主机/加入按钮、开始按钮。
##
## Session 是 autoload（project.godot 的 [autoload] 段），所以这里从
## "/root/Session" 取它 —— autoload 是**全局单例**，不属于"场景节点之间硬编码
## 绝对路径互相引用"那条约束（那条约束针对的是场景内的节点引用）。

## 加入房间用的地址。P1 只跑本机双窗口（Task 13 验收）；局域网地址输入留给后续任务。
const JOIN_ADDRESS := "127.0.0.1"

## 开局后要进的场景。任务 8 才建这个场景；缺失时交给 Router 安全跳过。
const GAME_SCENE := "res://scenes/game.tscn"

## 对局场景的路径（**可覆盖**）。
##
## 默认值与 GAME_SCENE 完全一致（既有公开行为不变），但它是一个**变量**，
## 这样测试可以注入一个**假路径**来强制走「场景缺失」分支 ——
## 覆盖就不必依赖「`res://scenes/game.tscn` 恰好还不存在」这个会随 Task 8 失效的前提。
##
## ★ **存在性判定与 router.goto() 的目标必须用同一个变量**：
##   一个用变量一个用常量的话，注入的路径和实际切换的路径会不一致。
var game_scene_path: String = GAME_SCENE

@onready var _roster: VBoxContainer = $Center/Panel/Margin/VBox/Roster
@onready var _status: Label = $Center/Panel/Margin/VBox/Status
@onready var _host_btn: Button = $Center/Panel/Margin/VBox/HostButton
@onready var _join_btn: Button = $Center/Panel/Margin/VBox/JoinButton
@onready var _start_btn: Button = $Center/Panel/Margin/VBox/StartButton

var _session: Session = null

## 已经建立过信号连接的 Session（换 Session 时要把旧连接断开）。
##
## ★ `_session` 是**可替换**的（测试会事后注入替身 Session）。
##   只在 _ready() 里连一次的话，连接会一直指着**旧**的那个 Session ——
##   替身发信号时大厅收不到 → 切场景逻辑看着像坏了，其实是指错了对象。
var _connected_session: Session = null


func _ready() -> void:
	_session = get_node_or_null("/root/Session")
	_host_btn.pressed.connect(_on_host)
	_join_btn.pressed.connect(_on_join)
	_start_btn.pressed.connect(_on_start)
	_connect_session_signals()
	_refresh()
	# ★ 上一次连接失败/超时的原因（可能是在对局场景里断的，这会儿才回到大厅）。
	_show_failure_reason()


## 把「上一次为什么断了」说清楚（连接超时 / 房主掉线）。
##
## ★ 为什么要有这一步：连接断了之后玩家只看到「房间没了」却不知道为什么
##   （2026-11-04 用户报障）。大厅是唯一能说清楚的地方。
func _show_failure_reason() -> void:
	if _session == null:
		return
	if not _session.has_method(&"failure_reason"):
		return
	var reason := str(_session.call(&"failure_reason"))
	if reason.is_empty():
		return
	_status.text = reason


## 接 Session 的信号（**针对当前的 self._session**）。
##
## ★ 每次拿到 Session 之后都要重新调一次（_ready / 建房 / 加入 / 开局之前）：
##   `_session` 可被替换 → 只在 _ready() 里连一次会连到**旧**的那个。
##   连之前先查 is_connected（连两次会报 "Signal already connected"）。
func _connect_session_signals() -> void:
	if _connected_session == _session:
		return
	if _connected_session != null:
		_disconnect_session_signals(_connected_session)
	_connected_session = _session
	if _session == null:
		return
	if not _session.roster_changed.is_connected(_on_roster):
		_session.roster_changed.connect(_on_roster)
	# ★ 连接断了 → 状态栏说清楚为什么（2026-11-04 用户报障）。
	if _session.has_signal(&"connection_lost") \
			and not _session.connection_lost.is_connected(_on_connection_lost):
		_session.connection_lost.connect(_on_connection_lost)
	# ★ 切场景**由 round_started 驱动**（两端对称）。
	#   房主点「开始」→ start_round() → round_started（同步）；
	#   客户端收到定向清单 → _apply_deal() → round_started。
	#   两端都从这里切进对局场景 → 行为完全一致（客户端不再卡在大厅）。
	if not _session.round_started.is_connected(_on_round_started):
		_session.round_started.connect(_on_round_started)


## 断开上一个 Session 的信号连接（大厅只听**一个** Session）。
func _disconnect_session_signals(s: Session) -> void:
	if s == null:
		return
	if s.is_connected(&"roster_changed", _on_roster):
		s.disconnect(&"roster_changed", _on_roster)
	if s.is_connected(&"round_started", _on_round_started):
		s.disconnect(&"round_started", _on_round_started)
	if s.is_connected(&"connection_lost", _on_connection_lost):
		s.disconnect(&"connection_lost", _on_connection_lost)


## Session 报告「连接断了」→ 状态栏说清楚原因。
func _on_connection_lost(reason: String) -> void:
	_refresh()
	if reason.is_empty():
		return
	_status.text = reason


func _on_host() -> void:
	if _session == null:
		return
	_connect_session_signals()
	var err := _session.host_game()
	if err != OK:
		_status.text = "创建房间失败（端口被占用？）"
		return
	# **先 host 成功，再挂到 MultiplayerAPI**：attach_to 在没有 peer 时是空操作。
	_session.apply_to_multiplayer()
	_status.text = "已创建房间，等待朋友加入…"


func _on_join() -> void:
	if _session == null:
		return
	_connect_session_signals()
	var err := _session.join_game(JOIN_ADDRESS)
	if err != OK:
		# ★ Session 会给出**具体**原因（例如「你已经创建了房间，不用再加入」）；
		#   没有具体原因才回退到通用文案（别让玩家对着「加入失败」猜）。
		_status.text = _join_failure_text()
		return
	# **先 join 成功，再挂到 MultiplayerAPI**（同上）。
	_session.apply_to_multiplayer()
	_status.text = "正在加入…"


## 加入失败时给玩家看的一句话。
##
## ★ 优先用 Session.failure_reason()（它知道到底是"已经建房了"还是"连不上"）；
##   没有就说通用的一句 —— 状态栏必须**说清楚**，别让玩家猜。
func _join_failure_text() -> String:
	if _session != null and _session.has_method(&"failure_reason"):
		var reason := str(_session.call(&"failure_reason"))
		if not reason.is_empty():
			return reason
	return "加入失败（地址不对？）"


func _on_start() -> void:
	# 只有房主能开局（一切联机判定都在房主执行）。
	if _session == null or not _session.is_host():
		return
	# ★ 重新接一次信号：`_session` 可能已经被换成替身（连接不许指着旧对象）。
	_connect_session_signals()
	# 对局场景还没建好时**不开回合**：Router 会安全跳过缺失的场景，
	# 于是就留下「回合开了但人还在大厅」的半成品 —— 牌已经发出去，
	# 人却卡在大厅里（Task 8 建好 game.tscn 之前不能这样）。
	# **判定与切换用的是同一个变量**（game_scene_path），不能一个用变量一个用常量。
	if not ResourceLoader.exists(game_scene_path):
		_status.text = "对局场景还没建好（%s 缺失），暂时开不了局" % game_scene_path
		return
	_session.start_round()
	# ★ 这里**不再**直接切场景：切场景统一由 round_started 信号驱动
	#   （见 _on_round_started）→ 房主与客户端**行为完全对称**，
	#   房主也不会在同一个回合里切两次场景。


## 回合开始（房主与客户端都会收到这个信号）→ 切进对局场景。
##
## ★ 用的是**同一个变量** game_scene_path（不许用常量 GAME_SCENE ——
##   上面那段注释已经写明：存在性判定与切换目标必须是同一个变量）。
func _on_round_started(_deal: Array) -> void:
	var router := get_node_or_null("/root/Router")
	if router != null:
		router.goto(game_scene_path)


func _on_roster(_peers: Array[int]) -> void:
	_refresh()


func _refresh() -> void:
	if _session == null:
		return
	for c in _roster.get_children():
		c.queue_free()
	for i in _session.peer_count():
		var l := Label.new()
		l.text = "玩家 %d" % (i + 1)
		_roster.add_child(l)
	_start_btn.disabled = not _session.is_host()
	if _session.is_host():
		_status.text = "房间已创建 · %d 人在线，等人齐了开始" % _session.peer_count()
