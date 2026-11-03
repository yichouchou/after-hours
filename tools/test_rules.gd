extends SceneTree

## Task 5：捣蛋裁决规则（纯逻辑层）单元测试。
##
## 断言分七组：
##   1. brief 原始断言（原样保留，不删、不改弱）
##   2. reason 取值（ok / caught / in_progress 与三条分支逐一对应）
##   3. 返回契约：三条分支的键集合**恰好**是 {success, reason, caught}
##      （brief 只查了第一个结果 r 的键；这里三条分支都要查，多一个键都算失败）
##   4. 进度边界（progress 正好 1.0 成功 / 0.999 失败）
##   5. 抓捕边界（距离正好等于 catch_dist 判被抓 / 刚大于不判被抓）
##   6. 警觉位 × 距离交叉（远 + 警觉不抓 / 近 + 不警觉不抓）
##   7. 缺省值、缺键、搭档四种组合、确定性
##
## 零失败惩罚：任何分支的返回值里都不允许出现「扣分 / 淘汰 / 扣命」字段。

var _total := 0

## brief 明列的惩罚性字段。
const FORBIDDEN_KEYS := ["penalty", "score_delta", "lives_lost", "eliminated"]

## 同一语义的更宽清单，防止换个名字漏进来。
const FORBIDDEN_KEYS_WIDE := ["score", "points", "score_loss", "life", "lives",
	"penalty", "penalized", "hp", "damage", "fail", "failed", "dead",
	"eliminated", "caught_penalty"]

## 返回值的完整键集合（不多不少）。
const EXPECTED_KEYS := ["success", "reason", "caught"]


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	# ==================================================================
	# 1. brief 原始断言（原样保留）
	# ==================================================================
	var r := Rules.evaluate(
		{"peer_id": 1, "behavior_id": &"steal_carrot", "target_id": 10, "progress": 1.0},
		{"nearest_guard_distance": 200.0, "guard_alerted": false, "has_partner": true,
		 "needs_partner": false, "guard_catch_distance": 24.0})
	fails += _check(bool(r["success"]), "守卫不在附近时捣蛋成功")
	fails += _check(not bool(r["caught"]), "安全时不被抓")

	# 守卫警觉且近 → 失败 + 被抓
	var r2 := Rules.evaluate(
		{"peer_id": 1, "behavior_id": &"steal_carrot", "target_id": 10, "progress": 1.0},
		{"nearest_guard_distance": 10.0, "guard_alerted": true, "has_partner": true,
		 "needs_partner": false, "guard_catch_distance": 24.0})
	fails += _check(not bool(r2["success"]), "被守卫盯着时捣蛋失败")
	fails += _check(bool(r2["caught"]), "被守卫盯着且距离近时被抓")

	# 需要搭档但没有 → 仍可完成（效率减半，不阻断）
	var r3 := Rules.evaluate(
		{"peer_id": 1, "behavior_id": &"prank_bench", "target_id": 10, "progress": 1.0},
		{"nearest_guard_distance": 200.0, "guard_alerted": false, "has_partner": false,
		 "needs_partner": true, "guard_catch_distance": 24.0})
	fails += _check(bool(r3["success"]), "缺搭档时仍能完成（不阻断）")

	# 进度不足 → 不算完成
	var r4 := Rules.evaluate(
		{"peer_id": 1, "behavior_id": &"steal_carrot", "target_id": 10, "progress": 0.4},
		{"nearest_guard_distance": 200.0, "guard_alerted": false, "has_partner": true,
		 "needs_partner": false, "guard_catch_distance": 24.0})
	fails += _check(not bool(r4["success"]), "进度不足不算完成")

	# 关键：任何情况下都不产生惩罚性字段
	for key in r.keys():
		fails += _check(not (key in FORBIDDEN_KEYS),
			"返回不含惩罚字段 %s" % key)

	# ==================================================================
	# 2. reason 取值（brief 没断言 reason 的值，这里补上）
	# ==================================================================
	fails += _check(str(r["reason"]) == "ok", "成功分支的 reason == \"ok\"")
	fails += _check(str(r2["reason"]) == "caught", "被抓分支的 reason == \"caught\"")
	fails += _check(str(r4["reason"]) == "in_progress", "进度不足分支的 reason == \"in_progress\"")
	fails += _check(str(r3["reason"]) == "ok", "缺搭档但完成的 reason == \"ok\"")
	# reason 与 success 必须自洽：只有 ok 才是成功。
	fails += _check(bool(r["success"]) == (str(r["reason"]) == "ok"),
		"success 与 reason \"ok\" 严格对应")
	fails += _check(bool(r2["success"]) == false and str(r2["reason"]) != "ok",
		"被抓时 success false 且 reason 不是 ok")
	fails += _check(bool(r4["success"]) == false and str(r4["reason"]) != "ok",
		"进度不足时 success false 且 reason 不是 ok")

	# ==================================================================
	# 3. 返回契约：三条分支的键集合都必须恰好是 {success, reason, caught}
	#    （brief 的循环只覆盖了第一个结果 r，这里补齐另外两条分支）
	# ==================================================================
	fails += _check(_has_exact_keys(r, EXPECTED_KEYS),
		"成功分支返回的键集合恰好是 {success, reason, caught}")
	fails += _check(_has_exact_keys(r2, EXPECTED_KEYS),
		"被抓分支返回的键集合恰好是 {success, reason, caught}")
	fails += _check(_has_exact_keys(r4, EXPECTED_KEYS),
		"进度不足分支返回的键集合恰好是 {success, reason, caught}")
	for k2 in r2.keys():
		fails += _check(not (k2 in FORBIDDEN_KEYS),
			"被抓分支返回不含惩罚字段 %s" % k2)
	for k4 in r4.keys():
		fails += _check(not (k4 in FORBIDDEN_KEYS),
			"进度不足分支返回不含惩罚字段 %s" % k4)
	for k3 in r3.keys():
		fails += _check(not (k3 in FORBIDDEN_KEYS),
			"缺搭档分支返回不含惩罚字段 %s" % k3)
	fails += _check(not _has_forbidden_key(r), "成功分支不含任何宽口径惩罚字段")
	fails += _check(not _has_forbidden_key(r2), "被抓分支不含任何宽口径惩罚字段")
	fails += _check(not _has_forbidden_key(r4), "进度不足分支不含任何宽口径惩罚字段")

	# ==================================================================
	# 4. 进度边界
	# ==================================================================
	var at_one := Rules.evaluate(
		{"progress": 1.0},
		{"nearest_guard_distance": 200.0, "guard_alerted": false, "guard_catch_distance": 24.0})
	fails += _check(bool(at_one["success"]), "progress 正好 1.0 判定成功")
	fails += _check(str(at_one["reason"]) == "ok", "progress 正好 1.0 的 reason == \"ok\"")
	var below_one := Rules.evaluate(
		{"progress": 0.999},
		{"nearest_guard_distance": 200.0, "guard_alerted": false, "guard_catch_distance": 24.0})
	fails += _check(not bool(below_one["success"]), "progress 0.999 判定失败（进度不足）")
	fails += _check(str(below_one["reason"]) == "in_progress", "progress 0.999 的 reason == \"in_progress\"")
	fails += _check(not bool(below_one["caught"]), "progress 0.999 时 caught 为 false")

	# ==================================================================
	# 5. 抓捕距离边界（实现是 <=）
	# ==================================================================
	var at_edge := Rules.evaluate(
		{"progress": 1.0},
		{"nearest_guard_distance": 24.0, "guard_alerted": true, "guard_catch_distance": 24.0})
	fails += _check(bool(at_edge["caught"]), "距离正好等于 catch_dist 判定被抓（<= 边界）")
	fails += _check(str(at_edge["reason"]) == "caught", "正好等于 catch_dist 的 reason == \"caught\"")
	fails += _check(not bool(at_edge["success"]), "正好等于 catch_dist 时 success 为 false")
	var just_over := Rules.evaluate(
		{"progress": 1.0},
		{"nearest_guard_distance": 24.01, "guard_alerted": true, "guard_catch_distance": 24.0})
	fails += _check(not bool(just_over["caught"]), "刚大于 catch_dist 不判被抓")
	fails += _check(bool(just_over["success"]), "刚大于 catch_dist 时仍成功")
	fails += _check(str(just_over["reason"]) == "ok", "刚大于 catch_dist 的 reason == \"ok\"")

	# ==================================================================
	# 6. 警觉位 × 距离交叉（两条最容易写错的分支）
	# ==================================================================
	var alerted_far := Rules.evaluate(
		{"progress": 1.0},
		{"nearest_guard_distance": 200.0, "guard_alerted": true, "guard_catch_distance": 24.0})
	fails += _check(not bool(alerted_far["caught"]), "守卫警觉但距离很远 → 不被抓")
	fails += _check(bool(alerted_far["success"]), "守卫警觉但距离很远 → 仍成功")
	fails += _check(str(alerted_far["reason"]) == "ok", "守卫警觉但距离很远 → reason == \"ok\"")
	var calm_near := Rules.evaluate(
		{"progress": 1.0},
		{"nearest_guard_distance": 1.0, "guard_alerted": false, "guard_catch_distance": 24.0})
	fails += _check(not bool(calm_near["caught"]), "距离很近但守卫不警觉 → 不被抓")
	fails += _check(bool(calm_near["success"]), "距离很近但守卫不警觉 → 仍成功")
	fails += _check(str(calm_near["reason"]) == "ok", "距离很近但守卫不警觉 → reason == \"ok\"")

	# ==================================================================
	# 7. 缺省值 / 缺键 / 搭档四种组合 / 确定性
	# ==================================================================
	# 缺省 guard_catch_distance → 按 CATCH_DISTANCE(24.0) 判定
	var dflt_in := Rules.evaluate(
		{"progress": 1.0},
		{"nearest_guard_distance": 24.0, "guard_alerted": true})
	fails += _check(bool(dflt_in["caught"]), "缺省 guard_catch_distance 时按 24.0 判定被抓")
	var dflt_out := Rules.evaluate(
		{"progress": 1.0},
		{"nearest_guard_distance": 24.01, "guard_alerted": true})
	fails += _check(not bool(dflt_out["caught"]), "缺省 guard_catch_distance 时 24.01 px 不被抓")
	fails += _check(is_equal_approx(Rules.CATCH_DISTANCE, 24.0),
		"Rules.CATCH_DISTANCE == 24.0（与 Task 4 GuardBrain.CATCH_DISTANCE 同值）")

	# 缺键 / 空字典不崩
	var empty := Rules.evaluate({}, {})
	fails += _check(not bool(empty["success"]), "空 action + 空 ctx → success 为 false")
	fails += _check(str(empty["reason"]) == "in_progress", "空 action + 空 ctx → reason == \"in_progress\"")
	fails += _check(not bool(empty["caught"]), "空 action + 空 ctx → caught 为 false")
	fails += _check(_has_exact_keys(empty, EXPECTED_KEYS), "空 action + 空 ctx 的键集合仍是 3 个")
	var no_ctx := Rules.evaluate({"progress": 1.0}, {})
	fails += _check(bool(no_ctx["success"]),
		"缺 ctx 键时 progress=1.0 仍成功（nearest 缺省 99999、alerted 缺省 false）")
	fails += _check(str(no_ctx["reason"]) == "ok", "缺 ctx 键时 reason == \"ok\"")
	fails += _check(not bool(no_ctx["caught"]), "缺 ctx 键时 caught 为 false")

	# 搭档四种组合都不阻断成功（brief 只测了其中一种）
	for has_p in [true, false]:
		for needs_p in [true, false]:
			var pc := Rules.evaluate(
				{"progress": 1.0},
				{"nearest_guard_distance": 200.0, "guard_alerted": false,
				 "has_partner": has_p, "needs_partner": needs_p, "guard_catch_distance": 24.0})
			fails += _check(bool(pc["success"]),
				"搭档组合 has_partner=%s / needs_partner=%s → 不阻断成功" % [has_p, needs_p])
			fails += _check(str(pc["reason"]) == "ok",
				"搭档组合 has_partner=%s / needs_partner=%s → reason == \"ok\"" % [has_p, needs_p])

	# 确定性：同样的 action + ctx 连调两次，结果完全一致（三条分支各查一遍）。
	fails += _check(_same_result(
		Rules.evaluate({"progress": 1.0}, {"nearest_guard_distance": 200.0, "guard_alerted": false}),
		Rules.evaluate({"progress": 1.0}, {"nearest_guard_distance": 200.0, "guard_alerted": false})),
		"成功分支连调两次结果一致")
	fails += _check(_same_result(
		Rules.evaluate({"progress": 1.0}, {"nearest_guard_distance": 10.0, "guard_alerted": true}),
		Rules.evaluate({"progress": 1.0}, {"nearest_guard_distance": 10.0, "guard_alerted": true})),
		"被抓分支连调两次结果一致")
	fails += _check(_same_result(
		Rules.evaluate({"progress": 0.4}, {"nearest_guard_distance": 200.0, "guard_alerted": false}),
		Rules.evaluate({"progress": 0.4}, {"nearest_guard_distance": 200.0, "guard_alerted": false})),
		"进度不足分支连调两次结果一致")

	print("")
	print("断言总数：%d" % _total)
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


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
	for k in d.keys():
		if String(k) in FORBIDDEN_KEYS_WIDE:
			return true
	return false


## 两个 evaluate() 返回值是否完全一致（逐字段比，不依赖容器比较语义）。
func _same_result(a: Dictionary, b: Dictionary) -> bool:
	if not _has_exact_keys(a, EXPECTED_KEYS) or not _has_exact_keys(b, EXPECTED_KEYS):
		return false
	return bool(a["success"]) == bool(b["success"]) \
		and str(a["reason"]) == str(b["reason"]) \
		and bool(a["caught"]) == bool(b["caught"])


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
