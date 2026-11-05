class_name MischiefProp
extends Node2D

## 一个可被捣蛋的道具（位置与 tag 来自 data/map.json）。
##
## 导出：
##   prop_tag  道具的类别 tag（与 Mischief.target_tag 同口径）
##   prop_id   道具的**数据 id**（房主侧「先到先得」台账用它做 key）
##   lamp_on   路灯的**初始**亮灭（只有路灯有意义）
##
## ★ 灯的亮灭契约（Task 9 已定；读取方是 scripts/guard.gd 的 _lamp_is_on()）：
##   优先级 = **meta "lamp_on" → 属性 lamp_on → 都没有就当亮着**。
##   → 本脚本**只写 meta**（meta 的优先级最高），
##     属性 lamp_on 保持为「作者设定的初始值」不动。
##     于是：没被动过 → 走**属性**那条路；动过 → 走 **meta** 那条路。

## 道具的类别 tag（与 Mischief.target_tag 同口径）。
@export var prop_tag: StringName = &""

## 道具的数据 id（房主侧「先到先得」台账的 key）。
@export var prop_id: int = 0

## 路灯的**初始**亮灭（true = 亮着）。
@export var lamp_on: bool = true


func _ready() -> void:
	set_meta("prop_tag", prop_tag)
	set_meta("prop_id", prop_id)
	# ★ 故意**不**写 meta "lamp_on"：
	#   没被动过的灯走「属性 lamp_on」那条读取路径；
	#   被 turn_lamp_off() 动过之后才走「meta lamp_on」那条（meta 优先级最高）。
	#   → 两条读取路径都有断言钉住（见 tools/test_interaction.gd 的 [§4-16]）。


## 把这盏灯**熄灭**（走 Task 9 的读取契约：写 meta "lamp_on"）。
func turn_lamp_off() -> void:
	Interaction.set_lamp_on(self, false)


## 把这盏灯**点亮**（走 Task 9 的读取契约：写 meta "lamp_on"）。
func turn_lamp_on() -> void:
	Interaction.set_lamp_on(self, true)


## ★ 素材按 2x 出图（贴图尺寸 = 世界尺寸 × 2），Sprite2D 用 scale 0.5 回到世界尺寸。
##   自动锚定：offset = (-w/2, -h) → 水平居中、底边贴地（对任意尺寸都成立）。
##
##   场景文件里的 offset 只是**默认值**；每种道具贴图尺寸不同，
##   所以由场景层（scripts/game_scene.gd 的 _build_props）在摆道具时调本函数重算。
func apply_texture(tex: Texture2D) -> void:
	if tex == null:
		return
	var sprite := get_node_or_null("Sprite2D") as Sprite2D
	if sprite == null:
		return
	sprite.texture = tex
	sprite.offset = Vector2(-tex.get_width() * 0.5, -tex.get_height())


## 灯的亮灭同步到画面：灯灭 → 灯光不可见 + 贴图压暗。
##
## ★ 读取路径收口到 Interaction.is_lamp_on() —— 与守卫的视野计算**同源**：
##   画面变暗的那一刻守卫也就看不见了；两者永远不会各说各话。
func _process(_delta: float) -> void:
	var light := get_node_or_null("PointLight2D") as PointLight2D
	if light == null:
		return
	var on := Interaction.is_lamp_on(self)
	light.visible = on
	var sprite := get_node_or_null("Sprite2D") as Sprite2D
	if sprite != null:
		sprite.modulate = Color.WHITE if on else Color(0.55, 0.55, 0.65)
