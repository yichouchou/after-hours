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


func _ready() -> void:
	_session = get_node_or_null("/root/Session")
	_host_btn.pressed.connect(_on_host)
	_join_btn.pressed.connect(_on_join)
	_start_btn.pressed.connect(_on_start)
	if _session != null:
		_session.roster_changed.connect(_on_roster)
	_refresh()


func _on_host() -> void:
	if _session == null:
		return
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
	var err := _session.join_game(JOIN_ADDRESS)
	if err != OK:
		_status.text = "加入失败（地址不对？）"
		return
	# **先 join 成功，再挂到 MultiplayerAPI**（同上）。
	_session.apply_to_multiplayer()
	_status.text = "正在加入…"


func _on_start() -> void:
	# 只有房主能开局（一切联机判定都在房主执行）。
	if _session == null or not _session.is_host():
		return
	# 对局场景还没建好时**不开回合**：Router 会安全跳过缺失的场景，
	# 于是就留下「回合开了但人还在大厅」的半成品 —— 牌已经发出去，
	# 人却卡在大厅里（Task 8 建好 game.tscn 之前不能这样）。
	# **判定与切换用的是同一个变量**（game_scene_path），不能一个用变量一个用常量。
	if not ResourceLoader.exists(game_scene_path):
		_status.text = "对局场景还没建好（%s 缺失），暂时开不了局" % game_scene_path
		return
	_session.start_round()
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
