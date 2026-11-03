class_name WorldMap
extends RefCounted

## 关卡数据：地面尺寸 + 各类道具的位置。**纯逻辑层**。
##
## 纯逻辑约束（与 scripts/game/ 其余文件同款）：不碰场景树 ——
## 本文件里只有 FileAccess / JSON，没有任何取场景节点的调用
## （那条约束由 tools/test_player.gd 扫源码把住）。
##
## 坐标约定：JSON 里写的是**格坐标**（整数），返回值里的点位是**像素坐标**
## （格坐标 × TILE）。size 返回的是**格数**（Vector2i）。
##
## 失败路径：返回 {"size": Vector2i.ZERO, "props": {}, "ok": false, "error": String}。
## 失败时 size 用**零值**而不是默认尺寸 —— 不返回一个"看起来正常"的地图，
## 调用方靠 "ok" 字段就能分辨成败。

## 一格的边长（px）。
const TILE := 32


## 读取地图数据。
##
## 返回：{ "size": Vector2i, "props": { StringName: Array[Vector2] }, "ok": bool, "error": String }
##   - props 的键是 StringName（与 Mischief.target_tag 同类型）。
##   - props 的值是像素坐标（格坐标 × TILE）的 Array[Vector2]。
## 失败时返回 ok=false、size=Vector2i.ZERO、props={}，绝不抛异常。
static func load_map(path: String = "res://data/map.json") -> Dictionary:
	var out: Dictionary = {
		"size": Vector2i.ZERO,
		"props": {},
		"ok": false,
		"error": "",
	}

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		out["error"] = "打不开地图数据: " + path
		push_error(out["error"])
		return out

	# JSON.parse_string() 把 [30,18] 解析成 [30.0, 18.0]（float）→ 下面显式 int()/float()
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		out["error"] = "地图数据不是对象: " + path
		push_error(out["error"])
		return out
	var root: Dictionary = parsed

	var size_raw: Variant = root.get("size", null)
	if typeof(size_raw) != TYPE_ARRAY or (size_raw as Array).size() < 2:
		out["error"] = "地图数据缺 size: " + path
		push_error(out["error"])
		return out
	var size_arr: Array = size_raw
	out["size"] = Vector2i(int(size_arr[0]), int(size_arr[1]))

	var props_raw: Variant = root.get("props", null)
	if typeof(props_raw) != TYPE_DICTIONARY:
		out["error"] = "地图数据缺 props: " + path
		push_error(out["error"])
		return out
	var props_dict: Dictionary = props_raw

	var props: Dictionary = {}
	for tag in props_dict.keys():
		var arr_raw: Variant = props_dict[tag]
		if typeof(arr_raw) != TYPE_ARRAY:
			continue
		var arr: Array = arr_raw
		var pts: Array[Vector2] = []
		for p in arr:
			if typeof(p) != TYPE_ARRAY or (p as Array).size() < 2:
				continue
			var pa: Array = p
			pts.append(Vector2(float(pa[0]) * TILE, float(pa[1]) * TILE))
		props[StringName(tag)] = pts

	out["props"] = props
	out["ok"] = true
	return out
