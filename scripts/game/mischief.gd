class_name Mischief
extends Resource

## 一种捣蛋行为的定义。纯数据，不依赖场景树。

@export var id: StringName = &""
@export var title: String = ""
@export var category: StringName = &""
@export var target_tag: StringName = &""
@export var needs_partner: bool = false
@export var duration: float = 1.0
@export var points: int = 10


static func load_all(path: String = "res://data/mischief.json") -> Array[Mischief]:
	var out: Array[Mischief] = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("打不开捣蛋数据: " + path)
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_ARRAY:
		push_error("捣蛋数据不是数组: " + path)
		return out
	for entry in parsed:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var m := Mischief.new()
		m.id = StringName(str(entry.get("id", "")))
		m.title = str(entry.get("title", ""))
		m.category = StringName(str(entry.get("category", "")))
		m.target_tag = StringName(str(entry.get("target_tag", "")))
		m.needs_partner = bool(entry.get("needs_partner", false))
		m.duration = float(entry.get("duration", 1.0))
		m.points = int(entry.get("points", 10))
		out.append(m)
	return out


static func find_by_id(all: Array[Mischief], id: StringName) -> Mischief:
	for m in all:
		if m.id == id:
			return m
	return null
