extends Control

## 结算页：每人一张「通缉令」。
##
## ★ 零失败惩罚：这里只是**信息陈列** —— 做了几条、被抓几次、捣蛋了哪几条。
##   没有名次、没有累计数值、没有任何负向后果的展示。
##
## ★ 载荷是**纯数据**（能跨进程传）：{ peer_id: { name, done, caught, mischief_titles } }。
##   每个 peer 一项，字段固定这四个。
##
## ★ 结算页是在 round_ended **之后**才被切换进来的 —— 信号在它进树之前
##   就已经发过了 → 载荷必须由对局场景先存下来（静态变量），
##   结算页进树时再取出来渲染。

## 待显示的结算载荷（跨场景传递用）。
##
## ★ 静态变量：结算页与对局场景是**两个不同的场景**，
##   中间隔着一次场景切换 → 没有别的通道能把载荷递过去。
static var _pending_summary: Dictionary = {}

@onready var _cards: HBoxContainer = $Center/Panel/Margin/HBox


## 存下待显示的结算载荷（由对局场景在切场景**之前**调用）。
static func set_pending_summary(summary: Dictionary) -> void:
	_pending_summary = summary.duplicate(true)


## 取待显示的结算载荷（副本；外部改不动内部状态）。
static func get_pending_summary() -> Dictionary:
	return _pending_summary.duplicate(true)


func _ready() -> void:
	_connect_session()
	var pending := get_pending_summary()
	if not pending.is_empty():
		show_summary(pending)


## 显示结算：每位玩家一张卡片。
##
## ★ 调用两次**不残留旧卡片**：先把旧卡片摘下来再释放
##   （queue_free 要到帧末才生效，直接遍历 get_children() 会把旧卡片算进去）。
func show_summary(summary: Dictionary) -> void:
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.queue_free()
	for peer_id in summary.keys():
		var info: Dictionary = summary[peer_id]
		var box := VBoxContainer.new()
		var title := Label.new()
		title.text = "玩家 %s" % str(info.get("name", peer_id))
		box.add_child(title)
		var stat := Label.new()
		stat.text = "捣蛋 %d 次    被抓 %d 次" % [int(info.get("done", 0)),
			int(info.get("caught", 0))]
		box.add_child(stat)
		var list := VBoxContainer.new()
		for t in info.get("mischief_titles", []):
			var l := Label.new()
			l.text = "· %s" % str(t)
			list.add_child(l)
		box.add_child(list)
		_cards.add_child(box)


## 接 Session 的回合结束信号（结算页自己也能收工通知 → 直接刷新）。
func _connect_session() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var session = tree.root.get_node_or_null("Session")
	if session == null:
		return
	if not session.has_signal(&"round_ended"):
		return
	var cb := Callable(self, "_on_round_ended")
	if not session.is_connected(&"round_ended", cb):
		session.connect(&"round_ended", cb)


func _on_round_ended(summary: Dictionary) -> void:
	show_summary(summary)
