extends SceneTree

## Task 4：守卫感知与状态机（纯逻辑层）单元测试。
##
## 断言分五组：
##   1. 视野锥形（正前方 / 正后方 / 超距 / 锥内 / 锥外 / 锥角边界 / 零向量 / 零距离 / 零半径）
##   2. 光照衰减（1.0 / 0.6 / 0.0 / 上钳到 1 / 下钳到 0）
##   3. 听觉（范围内 / 超范围 / hearing_range = 0 / 正好等于 hearing_range）
##   4. 状态迁移（看见 → CHASE / 只听声音 → SUSPICIOUS / 衰减归零 → PATROL / 怀疑度封顶）
##   5. 返回契约（键集合恰好 4 个，零失败惩罚）+ 确定性
##
## 零失败惩罚：update() 的返回值里不允许出现任何「扣分 / 淘汰 / 扣命」字段。

var _total := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	# ==================================================================
	# 1. 视野锥形
	#    angle_deg 是**整个锥形的张角**，半角 = angle_deg * 0.5；
	#    80° 张角 → 半角 40°。
	# ==================================================================
	var o := Vector2.ZERO
	var facing := Vector2.RIGHT
	fails += _check(GuardBrain.in_sight_cone(o, facing, Vector2(50, 0), 100, 80), "正前方可见")
	fails += _check(not GuardBrain.in_sight_cone(o, facing, Vector2(-50, 0), 100, 80), "正后方不可见")
	fails += _check(not GuardBrain.in_sight_cone(o, facing, Vector2(150, 0), 100, 80), "超出距离不可见")
	# 【夹具修正】brief 原断言用 (30,28)：偏离正前方 43.03° > 半角 40°，实际落在锥外，
	# 必然失败。换成真正在锥内的 (28,22)（偏离 38.16°）。
	fails += _check(GuardBrain.in_sight_cone(o, facing, Vector2(28, 22), 100, 80), "锥形边缘内可见")
	fails += _check(not GuardBrain.in_sight_cone(o, facing, Vector2(30, 40), 100, 80), "锥形边缘外不可见")
	# 补充：原夹具的 43.03° 方位确实在锥外；39.81° 确实在锥内。
	fails += _check(not GuardBrain.in_sight_cone(o, facing, Vector2(30, 28), 100, 80),
		"偏离 43° 不可见（原 brief 夹具的方位）")
	fails += _check(GuardBrain.in_sight_cone(o, facing, Vector2(30, 25), 100, 80),
		"偏离 39.8° 可见（贴近锥边缘）")
	# 锥角边界：刚好在锥内（39° < 半角 40°）/ 刚好在锥外（41° > 半角 40°）。
	# 留 ±1° 余量是为了躲开 normalized() 的浮点误差：实测正好 40° 时
	# dot = 0.76604443788528 < cos(40°) = 0.76604444311898（差 5.2e-9），
	# 把边界点判成锥外，所以不能把「正好 40°」写死成断言。
	fails += _check(GuardBrain.in_sight_cone(o, facing, _dir_at(39.0), 100, 80),
		"刚好在锥内（39° < 半角 40°）")
	fails += _check(not GuardBrain.in_sight_cone(o, facing, _dir_at(41.0), 100, 80),
		"刚好在锥外（41° > 半角 40°）")
	# 距离为 0（与守卫重合）→ 可见。
	fails += _check(GuardBrain.in_sight_cone(o, facing, o, 100, 80), "距离为 0（与守卫重合）可见")
	# facing 为零向量 → 不可见（没有朝向就没有锥形）。
	fails += _check(not GuardBrain.in_sight_cone(o, Vector2.ZERO, Vector2(50, 0), 100, 80),
		"facing 为零向量时不可见")
	# 视野半径为 0 → 不可见。
	fails += _check(not GuardBrain.in_sight_cone(o, facing, Vector2(50, 0), 0.0, 80),
		"视野半径为 0 时不可见")

	# ==================================================================
	# 2. 光照衰减（纯逻辑层只做 base_range * clamp(light_factor, 0, 1)）
	# ==================================================================
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(100, 1.0), 100), "全亮时视野不变")
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(100, 0.6), 60), "光照 0.6 时视野 60%")
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(100, 0.0), 0.0), "全黑时视野为 0")
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(100, 1.5), 100), "光照超过 1 被钳到 1")
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(100, -0.5), 0.0), "光照低于 0 被钳到 0")
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(0, 0.6), 0.0), "基础视野为 0 时仍然为 0")

	# ==================================================================
	# 3. 听觉
	# ==================================================================
	fails += _check(GuardBrain.hearing_reached(50, 100), "在听觉范围内")
	fails += _check(not GuardBrain.hearing_reached(150, 100), "超出听觉范围")
	fails += _check(not GuardBrain.hearing_reached(50, 0), "听觉范围为 0 时永远够不到")
	fails += _check(not GuardBrain.hearing_reached(0, 0), "听觉范围为 0 时连重合都够不到")
	fails += _check(GuardBrain.hearing_reached(100, 100), "距离正好等于听觉范围时够得到")
	fails += _check(not GuardBrain.hearing_reached(100.5, 100), "刚超出听觉范围够不到")

	# ==================================================================
	# 4. 状态迁移
	# ==================================================================
	# 枚举必须含全部 5 个状态（CARRY / RETURN 本任务只有枚举项，不实现搬运方法）。
	fails += _check(GuardBrain.State.size() == 5, "状态枚举含 5 项")
	fails += _check(GuardBrain.State.has("PATROL") and GuardBrain.State.has("SUSPICIOUS")
			and GuardBrain.State.has("CHASE") and GuardBrain.State.has("CARRY")
			and GuardBrain.State.has("RETURN"),
		"状态枚举含 PATROL/SUSPICIOUS/CHASE/CARRY/RETURN")

	# --- 巡逻 -> 追击 ---
	var b := GuardBrain.new()
	# 【夹具修正】brief 原用例把玩家放在 (50,0)，距离 50 > CATCH_DISTANCE(24)，
	# 「距离够近时判定抓获」必然失败。改为 (20,0)（24 px 以内）。
	var ctx := {
		"guard_pos": Vector2.ZERO, "guard_facing": Vector2.RIGHT,
		"player_pos": Vector2(20, 0), "player_visible": true, "noise_pos": Vector2.ZERO,
		"noise_active": false, "sight_range": 100.0, "sight_angle_deg": 80.0,
		"hearing_range": 0.0, "target_peer": 7, "light_factor": 1.0,
	}
	var r1: Dictionary = b.update(0.1, ctx)
	fails += _check(int(r1["state"]) == GuardBrain.State.CHASE, "看到玩家进入 CHASE")
	fails += _check(int(r1["target_peer"]) == 7, "锁定目标 peer")
	fails += _check(bool(r1["catch_player"]), "距离够近时判定抓获")

	# --- 抓取距离边界（CATCH_DISTANCE = 24 px，1 格 = 32 px）---
	var ctx_catch := ctx.duplicate()
	ctx_catch["player_pos"] = Vector2(20, 0)
	fails += _check(bool(GuardBrain.new().update(0.1, ctx_catch)["catch_player"]),
		"24 px 以内判定抓获")
	ctx_catch["player_pos"] = Vector2(24, 0)
	fails += _check(bool(GuardBrain.new().update(0.1, ctx_catch)["catch_player"]),
		"正好 24 px 判定抓获")
	ctx_catch["player_pos"] = Vector2(24.01, 0)
	fails += _check(not bool(GuardBrain.new().update(0.1, ctx_catch)["catch_player"]),
		"刚过 24 px 不判定抓获")
	ctx_catch["player_pos"] = Vector2(50, 0)
	fails += _check(not bool(GuardBrain.new().update(0.1, ctx_catch)["catch_player"]),
		"50 px 不判定抓获")

	# --- 听觉引起怀疑（只听到声音，不是 CHASE）---
	var b2 := GuardBrain.new()
	var ctx2 := ctx.duplicate()
	ctx2["player_visible"] = false
	ctx2["player_pos"] = Vector2(9999, 9999)
	ctx2["noise_active"] = true
	ctx2["noise_pos"] = Vector2(30, 0)
	ctx2["hearing_range"] = 100.0
	ctx2["sight_range"] = 10.0
	var r2: Dictionary = b2.update(0.1, ctx2)
	fails += _check(int(r2["state"]) != GuardBrain.State.CHASE, "只听到声音不当成 CHASE")
	fails += _check(float(r2["suspicion"]) > 0.0, "听到声音提升怀疑度")
	fails += _check(int(r2["state"]) == GuardBrain.State.SUSPICIOUS, "只听到声音进入 SUSPICIOUS")

	# --- 听觉够不到（hearing_range = 0）时不该被声音惊动 ---
	var ctx2_far := ctx2.duplicate()
	ctx2_far["hearing_range"] = 0.0
	var r2_far: Dictionary = GuardBrain.new().update(0.1, ctx2_far)
	fails += _check(is_equal_approx(float(r2_far["suspicion"]), 0.0),
		"听觉范围为 0 时声音不提升怀疑度")
	fails += _check(int(r2_far["state"]) == GuardBrain.State.PATROL,
		"听觉范围为 0 时保持 PATROL")

	# --- 看不见则怀疑度下降 ---
	var b3 := GuardBrain.new()
	b3.suspicion = 1.0
	var ctx3 := ctx.duplicate()
	ctx3["player_visible"] = false
	ctx3["noise_active"] = false
	var r3: Dictionary = b3.update(0.5, ctx3)
	fails += _check(float(r3["suspicion"]) < 1.0, "看不见时怀疑度下降")

	# --- 怀疑度归零后，SUSPICIOUS 回到 PATROL ---
	var b4 := GuardBrain.new()
	b4.update(0.1, ctx2)
	fails += _check(int(b4.state) == GuardBrain.State.SUSPICIOUS, "先进入 SUSPICIOUS")
	var r4: Dictionary = b4.update(0.5, ctx3)
	fails += _check(is_equal_approx(float(r4["suspicion"]), 0.0), "怀疑度衰减到 0")
	fails += _check(int(r4["state"]) == GuardBrain.State.PATROL, "怀疑度归零后回到 PATROL")

	# --- 怀疑度有上限（不会无限增长）---
	var b5 := GuardBrain.new()
	for i in 200:
		b5.update(0.1, ctx)
	fails += _check(is_equal_approx(float(b5.suspicion), 1.5),
		"连续看见玩家时怀疑度封顶 1.5（不无限增长）")
	var b6 := GuardBrain.new()
	for i in 200:
		b6.update(0.1, ctx2)
	fails += _check(is_equal_approx(float(b6.suspicion), 0.5),
		"连续听到声音时怀疑度封顶 0.5（不无限增长）")

	# ==================================================================
	# 5. 返回契约（零失败惩罚）+ 确定性
	# ==================================================================
	var expected_keys := ["state", "target_peer", "suspicion", "catch_player"]
	fails += _check(_has_exact_keys(r1, expected_keys),
		"update() 返回的键集合恰好是 {state, target_peer, suspicion, catch_player}")
	fails += _check(_has_exact_keys(r2, expected_keys),
		"听觉场景返回的键集合同样是 4 个")
	fails += _check(not _has_forbidden_key(r1),
		"返回值里没有任何扣分 / 淘汰 / 扣命字段")

	# 确定性：同一个 ctx，两个新实例的结果完全一致。
	var d1: Dictionary = GuardBrain.new().update(0.1, ctx)
	var d2: Dictionary = GuardBrain.new().update(0.1, ctx)
	fails += _check(_same_result(d1, d2), "同一个 ctx 在两个新实例上结果一致（看见玩家场景）")
	var e1: Dictionary = GuardBrain.new().update(0.1, ctx2)
	var e2: Dictionary = GuardBrain.new().update(0.1, ctx2)
	fails += _check(_same_result(e1, e2), "同一个 ctx 在两个新实例上结果一致（听觉场景）")

	# 同一个实例连调两次：离散输出保持一致；怀疑度按状态机累积（这是规格，不是非确定性）。
	var b7 := GuardBrain.new()
	var s1: Dictionary = b7.update(0.1, ctx)
	var s2: Dictionary = b7.update(0.1, ctx)
	fails += _check(int(s1["state"]) == int(s2["state"])
			and int(s1["target_peer"]) == int(s2["target_peer"])
			and bool(s1["catch_player"]) == bool(s2["catch_player"]),
		"同一个实例连调两次：状态 / 目标 / 抓获判定保持一致")
	fails += _check(float(s2["suspicion"]) > float(s1["suspicion"]),
		"同一个实例连调两次：怀疑度按状态机累积")

	# ctx 缺省值：不崩、保持 PATROL、键集合不变。
	var r_min: Dictionary = GuardBrain.new().update(0.016, {})
	fails += _check(int(r_min["state"]) == GuardBrain.State.PATROL, "空 ctx 不崩且保持 PATROL")
	fails += _check(_has_exact_keys(r_min, expected_keys), "空 ctx 的返回值键集合仍是 4 个")
	# 缺省 light_factor（= 1.0）与显式写 1.0 结果一致。
	var ctx_no_light := ctx.duplicate()
	ctx_no_light.erase("light_factor")
	var n1: Dictionary = GuardBrain.new().update(0.1, ctx)
	var n2: Dictionary = GuardBrain.new().update(0.1, ctx_no_light)
	fails += _check(_same_result(n1, n2), "缺省 light_factor 与显式 1.0 结果一致")

	# ==================================================================
	# 6. data/guards.json 的数据契约（Task 11 会按它生成守卫）
	# ==================================================================
	fails += _check_guards_data()

	print("")
	print("断言总数：%d" % _total)
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


## 以给定角度（度）取一个 50 px 长的方向向量。
func _dir_at(deg: float, dist: float = 50.0) -> Vector2:
	var r := deg_to_rad(deg)
	return Vector2(cos(r), sin(r)) * dist


## 返回字典的键集合是否恰好等于期望集合（多一个键都算失败）。
func _has_exact_keys(d: Dictionary, expected: Array) -> bool:
	if d.size() != expected.size():
		return false
	for k in expected:
		if not d.has(k):
			return false
	return true


## 零失败惩罚：返回值里不允许出现扣分 / 淘汰 / 扣命一类字段。
func _has_forbidden_key(d: Dictionary) -> bool:
	var forbidden := ["score", "points", "life", "lives", "penalty", "eliminated",
		"hp", "damage", "fail", "failed", "dead"]
	for k in d.keys():
		if String(k) in forbidden:
			return true
	return false


## 两个 update() 返回值是否完全一致（逐字段比，避免依赖容器比较语义）。
func _same_result(a: Dictionary, b: Dictionary) -> bool:
	if not _has_exact_keys(a, ["state", "target_peer", "suspicion", "catch_player"]):
		return false
	if not _has_exact_keys(b, ["state", "target_peer", "suspicion", "catch_player"]):
		return false
	return int(a["state"]) == int(b["state"]) \
		and int(a["target_peer"]) == int(b["target_peer"]) \
		and is_equal_approx(float(a["suspicion"]), float(b["suspicion"])) \
		and bool(a["catch_player"]) == bool(b["catch_player"])


## data/guards.json 的结构契约：1 个守卫（老陈）+ 三类台词。
func _check_guards_data() -> int:
	var fails := 0
	var f := FileAccess.open("res://data/guards.json", FileAccess.READ)
	if f == null:
		return _check(false, "data/guards.json 可读")
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	fails += _check(typeof(parsed) == TYPE_ARRAY, "data/guards.json 顶层是数组")
	if typeof(parsed) != TYPE_ARRAY:
		return fails
	var arr: Array = parsed
	fails += _check(arr.size() == 1, "P1 只有 1 个守卫（实际 %d）" % arr.size())
	if arr.size() == 0:
		return fails
	var g: Dictionary = arr[0]
	fails += _check(str(g.get("id", "")) == "old_chen", "守卫 id = old_chen")
	fails += _check(str(g.get("name", "")) == "老陈", "守卫名字 = 老陈")
	fails += _check(int(g.get("sight_range", 0)) == 96, "守卫视野半径 = 96 px（3 格）")
	fails += _check(int(g.get("sight_angle_deg", 0)) == 80, "守卫视野张角 = 80°")
	fails += _check(int(g.get("hearing_range", 0)) == 128, "守卫听觉半径 = 128 px（4 格）")
	var lines: Dictionary = g.get("lines", {})
	fails += _check(lines.has("spotted") and lines.has("caught") and lines.has("missing"),
		"守卫台词含 spotted / caught / missing 三类")
	return fails


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
