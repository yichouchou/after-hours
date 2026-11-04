extends CanvasLayer

## HUD：左上角**自己那一份**捣蛋清单、右上角提示、中间的吐槽气泡。
##
## ★ 表现层：不参与任何联机判定（不裁决、不改任何游戏状态）。
## ★ 气泡**只有被抓的那一方**弹（不是全局播报）——
##   由对局场景在 caught_player_evt 里按本地 peer id 判断后调用。
##
## ★ 清单只显示**本地玩家自己那一份**（房主是裁判，能看见所有人的牌；
##   但 HUD 只显示自己的那一份 —— 那是玩家该知道的信息）。

## 气泡显示时长（秒）。
const BUBBLE_DURATION := 2.5

@onready var _card_list: VBoxContainer = $CardList
@onready var _hint: Label = $Hint
@onready var _bubble: Label = $Bubble
@onready var _bubble_timer: Timer = $BubbleTimer


func _ready() -> void:
	_bubble.visible = false
	if not _bubble_timer.timeout.is_connected(_on_bubble_timeout):
		_bubble_timer.timeout.connect(_on_bubble_timeout)


## 设置清单（每行一条）。空数组 = 清空。
func set_card_list(titles: Array[String]) -> void:
	for c in _card_list.get_children():
		# 先摘下来再释放：queue_free 要到帧末才生效，
		# 直接遍历 get_children() 会把旧行一起算进去。
		_card_list.remove_child(c)
		c.queue_free()
	for i in titles.size():
		var l := Label.new()
		l.text = "□ %s" % titles[i]
		_card_list.add_child(l)


## 设置提示文字（右上角）。
func set_hint(text: String) -> void:
	_hint.text = text


## 弹吐槽气泡（被抓时用）。
func show_bubble(text: String) -> void:
	_bubble.text = text
	_bubble.visible = true
	_bubble_timer.start(BUBBLE_DURATION)


## 气泡超时 → 收起。
func _on_bubble_timeout() -> void:
	_bubble.visible = false
