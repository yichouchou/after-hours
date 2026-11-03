class_name Interaction
extends RefCounted

## 捣蛋交互的**纯逻辑层**。三块能力：
##
##   1) 找道具：find_prop_in_range（Node 入口）/ find_nearest_by_data（纯数据入口）
##   2) 效率倍率：effective_duration（缺搭档 → 所需时间 × 2）
##   3) 归属台账：ClaimLedger（**房主侧**的「先到先得」）
##
## ★ 纯逻辑约束（与 scripts/game/ 其余文件同款）：
##   * **不调用**任何取场景树的 API（get_tree / get_node 之类）
##   * 对**脱离场景树**的节点也能正常工作（测试里就是这么用的）
##   * FileAccess / JSON 允许

## 缺搭档时所需时间的倍率。
##
## 规则（控制器裁定）：需要搭档的行为、场上**没有**搭档 → 所需时间是原来的 2 倍
## （= 效率减半：效率减半 ⇔ 所需时间翻倍）。
const PARTNER_SLOWDOWN := 2.0

## 搭档判定半径（px）：两名玩家在**同一个目标**这么近以内，算「在协作」。
const PARTNER_RADIUS := 64.0

## 守卫网络编号（guard_wire_id）的起始值。
const GUARD_WIRE_ID_BASE := 1


## 找范围内**最近**的道具。
##
## ★ 并列规则（写死，必须与断言一致）：
##   判据是 `d <= best_d` → **距离相等时取遍历顺序靠后的那个**。
##   （best_d 的初值就是 radius → 正好落在半径边缘上的道具也算命中。）
##   这条规则只管「离得最近」；「同一个目标归谁」由**房主侧**的 ClaimLedger 裁决
##   —— 不要在这里混两套语义。
##
## props 的元素是 Node2D（节点可以**不在场景树里**）。
static func find_prop_in_range(player_pos: Vector2, props: Array, radius: float) -> Node:
	var best: Node = null
	var best_d := radius
	for p in props:
		var n2d := p as Node2D
		if n2d == null:
			continue
		var d := player_pos.distance_to(n2d.global_position)
		if d <= best_d:
			best_d = d
			best = n2d
	return best


## 纯数据入口：找范围内最近的一条。
##
## entries 的每项形如 {"id": int, "tag": StringName, "position": Vector2}。
## 返回**命中那一条的副本**，没命中返回 {}（空字典）。
##
## ★ 与 find_prop_in_range 的并列规则**完全一致**（距离相等 → 取遍历顺序靠后的那个），
##   所以同一组数据走两个入口得到的结论必然相同。
static func find_nearest_by_data(player_pos: Vector2, entries: Array, radius: float) -> Dictionary:
	var best: Dictionary = {}
	var best_d := radius
	for e in entries:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = e
		var pos_v: Variant = entry.get("position", null)
		if typeof(pos_v) != TYPE_VECTOR2:
			continue
		var d := player_pos.distance_to(pos_v)
		if d <= best_d:
			best_d = d
			best = entry.duplicate()
	return best


## 捣蛋一条行为**实际要花的时间**（秒）。
##
## 规则（控制器裁定）：
##   * 行为需要搭档（Mischief.needs_partner）而**场上没有搭档** → duration × 2
##   * 其余情况 → duration 原值
##
## ★ needs_partner 取自**那张牌自己的字段**（不许硬编码 true/false）。
## 纯函数、可单测。
static func effective_duration(m: Mischief, has_partner: bool) -> float:
	if m == null:
		return 0.0
	if m.needs_partner and not has_partner:
		return m.duration * PARTNER_SLOWDOWN
	return m.duration


## 场上是否有**另一个**玩家在同一目标旁边（= 真正的搭档状态）。
##
## players：[{ "peer_id": int, "position": Vector2 }]
## at_pos：那个目标的坐标（以捣蛋者的位置为参照 —— 两人做的是**同一个**目标）。
##
## ★ 本函数只回答「有没有搭档」，不产生任何惩罚性后果。
static func has_partner_near(players: Array, peer_id: int, at_pos: Vector2,
		radius: float = PARTNER_RADIUS) -> bool:
	for p in players:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = p
		if int(d.get("peer_id", 0)) == peer_id:
			continue
		var pos_v: Variant = d.get("position", null)
		if typeof(pos_v) != TYPE_VECTOR2:
			continue
		if at_pos.distance_to(pos_v) <= radius:
			return true
	return false


## 守卫的**网络编号**（guard_wire_id）分配规则。
##
## ★ 规则（派单 §4-21）：
##   * 编号必须**唯一** —— 线上只有 int，客户端**没法**从 int 反查数据 id
##   * 与 data/guards.json 的**顺序确定性绑定**（第 n 个 → GUARD_WIRE_ID_BASE + n）
##   * **不许依赖默认值 1**
##
## 输入是数据 id 的数组（按 guards.json 的顺序），返回 {数据 id(StringName): 编号(int)}。
static func assign_guard_wire_ids(guard_ids: Array) -> Dictionary:
	var out: Dictionary = {}
	for i in guard_ids.size():
		var key := StringName(str(guard_ids[i]))
		if out.has(key):
			continue  # 数据 id 重复 → 保持第一次的编号（不覆盖）
		out[key] = GUARD_WIRE_ID_BASE + out.size()
	return out


## 把路灯接进守卫。**只走 lamp_root 这一条注入通道**。
##
## ★ 同一盏灯**只能选一种注入方式**（set_lamps() 数组 **或** lamp_root 子节点）：
##   两种都上 → guard.gd 的 _lamp_states() 会把它收**两遍** → 算成两盏熄灭的灯
##   → light_factor = 0.6 × 0.6 = 0.36（而不是 0.6）。
##   → 本函数**只**调 set_lamp_root()，**绝不**调 set_lamps()。
static func attach_lamps(guard: Node, lamp_root: Node2D) -> bool:
	if guard == null or lamp_root == null:
		return false
	if not guard.has_method(&"set_lamp_root"):
		return false
	guard.call(&"set_lamp_root", lamp_root)
	return true


## 熄灭 / 点亮一盏灯。**必须走 Task 9 已定的读取契约**：
##
##   优先级 = **meta "lamp_on" → 属性 lamp_on → 都没有就当亮着**
##   （读取方是 scripts/guard.gd 的 _lamp_is_on()，本文件**不许**自创读法）。
##
## → 这里**只写 meta "lamp_on"**（meta 的优先级最高），
##   属性 lamp_on 保持为「作者设定的初始值」不动。
static func set_lamp_on(node: Node, on: bool) -> bool:
	if node == null:
		return false
	node.set_meta("lamp_on", bool(on))
	return true


## 房主侧的「先到先得」台账：target_id → peer_id。
##
## ★ 归属裁决在**房主侧** —— Rules 是无状态的单次裁决，**不**裁决归属
##   （见 scripts/game/rules.gd 的说明）。两名玩家对同一个 target_id 提交时，
##   先到的占住，后到的**落败**。
##
## ★ 零失败惩罚：落败**不产生任何惩罚性后果**，只是这一条行为算没完成。
##   → 本类只回答「归谁」，**不返回任何惩罚性信息**。
class ClaimLedger extends RefCounted:
	var _claims: Dictionary = {}

	## 尝试占住 target_id。true = 占住了；false = 已被别人占走（落败）。
	func claim(target_id: int, peer_id: int) -> bool:
		if _claims.has(target_id):
			return false
		_claims[target_id] = peer_id
		return true

	## 这个 target_id 现在归谁（没人占 = 0）。
	func owner_of(target_id: int) -> int:
		return int(_claims.get(target_id, 0))

	## 这个 target_id 已经被占了吗。
	func is_claimed(target_id: int) -> bool:
		return _claims.has(target_id)

	## 已占住的目标数。
	func size() -> int:
		return _claims.size()
