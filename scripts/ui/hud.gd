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

## 「收工」被按下（**只有房主能点** —— 可用性由对局场景按 Session.is_host() 控制）。
signal finish_pressed

@onready var _card_list: VBoxContainer = $CardList
@onready var _hint: Label = $Hint
@onready var _bubble: Label = $Bubble
@onready var _bubble_timer: Timer = $BubbleTimer
@onready var _finish_btn: Button = $FinishButton


func _ready() -> void:
	_bubble.visible = false
	if not _bubble_timer.timeout.is_connected(_on_bubble_timeout):
		_bubble_timer.timeout.connect(_on_bubble_timeout)
	if not _finish_btn.pressed.is_connected(_on_finish_pressed):
		_finish_btn.pressed.connect(_on_finish_pressed)


## 「收工」按钮的可用性（**只有房主可点**）。
##
## 非房主：置灰（disabled == true）→ 点不动。
func set_finish_enabled(enabled: bool) -> void:
	_finish_btn.disabled = not enabled


## 「收工」按钮被按下 → 通知对局场景（组装摘要 + 广播收工）。
func _on_finish_pressed() -> void:
	finish_pressed.emit()


## 清单每一行的字号。
##
## ★ 字号**直接设在这几个 Label 上**（add_theme_font_size_override）——
##   不是设在 hud.tscn 的 CardList 上：**theme_override 不往下传给子节点**
##   （Container 的 theme_override 只影响它自己），设在容器上等于没设。
const CARD_FONT_SIZE := 13


## 设置清单（每行一条）。空数组 = 清空。
##
## ★ 每行**换行显示**（autowrap）：
##   清单面板只有 150 px 宽（视口 640 → ≈23%），而最长的标题
##   「把长椅搬到池塘边看日落」有 11 个字 —— 不换行的话这一行要 191 px，
##   而 **VBoxContainer 的 size 会被子节点的最小宽度顶开**
##   （Control.size 不小于 get_combined_minimum_size()）
##   → 面板被顶成 191 px，"收窄"等于白做，标题照样压到画面中央
##   （玩家永远在正中，那正是最不该被字挡住的地方）。
##   → 换行之后标签的最小宽度回到 1 px，面板才真的保持 150 px。
##   （实测数据见 .superpowers/sdd/.../_tmp_task14/probe_hud_cardlist.gd）
##
## ★★ **绝不能同时开 clip_text**（2026-11-05 实测踩到）：
##   Godot 4 的 Label.get_minimum_size() 在「开了 autowrap」时会返回
##       Size2(1, clip_text ? 1 : 实际文字高度)
##   → 一旦 clip_text = true，最小高度被**压成 1 px**
##   → VBoxContainer 给每个 Label 1 px 高 → **字根本画不出来**
##   （面板宽度照样是 150，get_line_count() 照样是 2 —— 只有实机截图才看得出来）
##   → 所以只开 autowrap，不开 clip_text。
func set_card_list(titles: Array[String]) -> void:
	for c in _card_list.get_children():
		# 先摘下来再释放：queue_free 要到帧末才生效，
		# 直接遍历 get_children() 会把旧行一起算进去。
		_card_list.remove_child(c)
		c.queue_free()
	for i in titles.size():
		var l := Label.new()
		l.text = "□ %s" % titles[i]
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.add_theme_font_size_override("font_size", CARD_FONT_SIZE)
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
