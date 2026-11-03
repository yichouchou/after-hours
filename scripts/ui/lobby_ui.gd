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
	_session.start_round()
	var router := get_node_or_null("/root/Router")
	if router != null:
		router.goto(GAME_SCENE)


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
