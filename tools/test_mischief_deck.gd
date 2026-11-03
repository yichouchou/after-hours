extends SceneTree

## 清单生成规则的单元测试。全部是纯逻辑，不需要场景树。

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0
	var all := Mischief.load_all()
	fails += _check(all.size() == 10, "P1 有 10 种行为，实际 %d" % all.size())

	# 每种行为字段完整
	for m in all:
		fails += _check(m.id != "" and m.title != "" and m.category != "" and m.target_tag != "",
			"行为 %s 字段完整" % m.id)

	var tags: Array[StringName] = []
	for m in all:
		tags.append(m.target_tag)

	for pc in [2, 3, 4, 6]:
		var rng := RandomNumberGenerator.new()
		rng.seed = 12345 + pc
		var deal := MischiefDeck.generate(all, pc, rng, tags)
		fails += _check(deal.size() == pc, "%d 人局分 %d 份" % [pc, deal.size()])

		var expect_n: int = clampi(pc + 1, 3, 5)
		for p in deal:
			fails += _check(p.size() == expect_n, "%d 人局每人 %d 张（实际 %d）" % [pc, expect_n, p.size()])

		# 规则 3：同类不超过 2
		var cats := {}
		for m in deal[0]:
			cats[m.category] = int(cats.get(m.category, 0)) + 1
		var over := false
		for c in cats:
			if int(cats[c]) > 2:
				over = true
		fails += _check(not over, "%d 人局同类不超过 2 张" % pc)

		# 规则 4/5
		var has_noise_or_decor := false
		var has_prank := false
		for m in deal[0]:
			if m.category == "noise" or m.category == "decor":
				has_noise_or_decor = true
			if m.category == "prank":
				has_prank = true
		fails += _check(has_noise_or_decor, "%d 人局至少有 1 张 noise/decor" % pc)
		fails += _check(has_prank, "%d 人局至少有 1 张 prank" % pc)

		# 规则 6：两人局两人拿到的是不同子集
		if pc >= 2:
			var a := _ids(deal[0])
			var b := _ids(deal[1])
			fails += _check(a != b, "%d 人局不同玩家牌组不同" % pc)

	# 目标不在地图上的行为应被过滤
	var only_carrot: Array[StringName] = [&"carrot"]
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 999
	var deal2 := MischiefDeck.generate(all, 2, rng2, only_carrot)
	var all_carrot := true
	for m in deal2[0]:
		if m.target_tag != &"carrot":
			all_carrot = false
	fails += _check(all_carrot, "只发目标存在的牌")

	# 确定性：同种子同结果
	var r1 := RandomNumberGenerator.new()
	r1.seed = 777
	var r2 := RandomNumberGenerator.new()
	r2.seed = 777
	fails += _check(_ids(MischiefDeck.generate(all, 3, r1, tags)[0]) ==
		_ids(MischiefDeck.generate(all, 3, r2, tags)[0]), "同种子结果一致")

	# ------------------------------------------------------------------
	# 以下为 task-3 修复轮 1 的补充断言（审查要求：规则 3/4/5 覆盖每一份清单、
	# 规则 6 覆盖所有两两组合、样本补上 5 人局并扩到 12 个种子）
	# ------------------------------------------------------------------

	# find_by_id：命中一条 + 找不到返回 null
	var found := Mischief.find_by_id(all, &"noise_pot")
	fails += _check(found != null and found.id == &"noise_pot", "find_by_id 命中 noise_pot")
	var missing := Mischief.find_by_id(all, &"no_such_mischief")
	fails += _check(missing == null, "find_by_id 找不到时返回 null")

	# 全量断言：2-6 人局 × 12 个种子
	#   规则 1 每人恒为 clampi(pc+1, 3, 5) 张
	#   规则 3/4/5 每一份清单都成立（不只 deal[0]）
	#   规则 6 任意两份清单都不相同（遍历所有两两组合）
	for pc in [2, 3, 4, 5, 6]:
		var expect_n: int = clampi(pc + 1, 3, 5)
		var bad_count: Array[String] = []
		var bad_rules: Array[String] = []
		var bad_rule6: Array[String] = []
		for s in 12:
			var rng := RandomNumberGenerator.new()
			# s = 0 时就是 brief 原测试用的种子 12345 + pc
			rng.seed = 12345 + pc + s * 7
			var deal := MischiefDeck.generate(all, pc, rng, tags)
			if deal.size() != pc:
				bad_count.append("种子 %d: 分了 %d 份" % [s, deal.size()])
			for p in deal:
				if p.size() != expect_n:
					bad_count.append("种子 %d: 某人 %d 张（应 %d）" % [s, p.size(), expect_n])
			bad_rules.append_array(_rule_violations(deal))
			bad_rule6.append_array(_duplicate_hands(deal))
		fails += _check(bad_count.is_empty(),
			"%d 人局 × 12 种子：每人恒 %d 张%s" % [pc, expect_n, _first(bad_count)])
		fails += _check(bad_rules.is_empty(),
			"%d 人局 × 12 种子：每份清单都满足规则 3/4/5%s" % [pc, _first(bad_rules)])
		fails += _check(bad_rule6.is_empty(),
			"%d 人局 × 12 种子：任意两份清单的行为集合都不相同%s" % [pc, _first(bad_rule6)])

	# 集合口径自检：两份"集合相同、顺序不同"的清单必须被判为撞车。
	# 旧的逐位比较看不出这种撞车 —— 上一轮审查实测 6 人局 14.23% 的局存在这种撞车。
	var fake := _fake_same_set_deal()
	fails += _check(_ids(fake[0]) != _ids(fake[1]),
		"集合口径自检：这两份清单的有序 id 列表确实不同（旧的有序比较会漏掉它）")
	fails += _check(not _duplicate_hands(fake).is_empty(),
		"集合口径自检：集合相同但顺序不同的两份清单被判为重复")

	# 稀缺但仍够 3 张且类别够分：每人仍拿满 clampi(2+1,3,5)=3 张，且用尽所有可用牌
	var scarce: Array[StringName] = [&"carrot", &"pot"]
	var rng3 := RandomNumberGenerator.new()
	rng3.seed = 4242
	var deal3 := MischiefDeck.generate(all, 2, rng3, scarce)
	fails += _check(deal3.size() == 2, "稀缺目标局仍分 2 份")
	for p in deal3:
		fails += _check(p.size() == 3, "稀缺目标局每人仍 3 张（实际 %d）" % p.size())
	var scarce_ids := _ids(deal3[0])
	var scarce_ids2 := _ids(deal3[1])
	fails += _check(scarce_ids.size() == 3 and scarce_ids2.size() == 3,
		"稀缺目标局两人各 3 张可用牌")
	var only_scarce := true
	for m in deal3[0]:
		if m.target_tag != &"carrot" and m.target_tag != &"pot":
			only_scarce = false
	fails += _check(only_scarce, "稀缺目标局只发目标存在的牌")

	# 极端：只剩 1 张可用行为时也不能返回空清单或崩溃，每人仍应是 3 张
	var tiny: Array[StringName] = [&"carrot"]
	var rng4 := RandomNumberGenerator.new()
	rng4.seed = 31337
	var deal4 := MischiefDeck.generate(all, 2, rng4, tiny)
	fails += _check(deal4.size() == 2, "极端稀缺仍分 2 份")
	for p in deal4:
		fails += _check(p.size() == 3, "极端稀缺每人仍 3 张（实际 %d）" % p.size())
	var all_carrot4 := true
	for m in deal4[0]:
		if m.target_tag != &"carrot":
			all_carrot4 = false
	fails += _check(all_carrot4, "极端稀缺只发目标存在的牌")
	# 固定"允许重复"这个契约：池子只有 1 张牌时，两份清单必然相同（不是缺陷）
	fails += _check(_ids(deal4[0]) == _ids(deal4[1]),
		"极端稀缺契约：池子只有 1 张牌时两份清单必然相同（允许重复，不算失败）")

	# 牌数为 0 或池子为空时不能崩
	var rng5 := RandomNumberGenerator.new()
	rng5.seed = 5
	var deal5 := MischiefDeck.generate(all, 0, rng5, tags)
	fails += _check(deal5.is_empty(), "0 人局返回空清单")
	var no_tags: Array[StringName] = []
	var deal6 := MischiefDeck.generate(all, 2, rng5, no_tags)
	fails += _check(deal6.size() == 2, "无可用目标仍分 2 份")
	for p in deal6:
		fails += _check(p.is_empty(), "无可用目标时该份为空而不是崩溃")
	# all 为空时同样返回 player_count 份空清单
	var deal7 := MischiefDeck.generate([] as Array[Mischief], 2, rng5, tags)
	fails += _check(deal7.size() == 2, "行为表为空仍分 2 份")
	for p in deal7:
		fails += _check(p.is_empty(), "行为表为空时该份为空而不是崩溃")

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _ids(list: Array) -> Array:
	var out := []
	for m in list:
		out.append(String(m.id))
	return out


## 逐份清单检查规则 3（同类 ≤ 2）、规则 4（≥1 张 noise/decor）、规则 5（≥1 张 prank）。
## 返回可读的违规描述列表。
func _rule_violations(deal: Array) -> Array[String]:
	var bad: Array[String] = []
	for pi in deal.size():
		var cats := {}
		var has_noise_or_decor := false
		var has_prank := false
		for m in deal[pi]:
			cats[m.category] = int(cats.get(m.category, 0)) + 1
			if m.category == "noise" or m.category == "decor":
				has_noise_or_decor = true
			if m.category == "prank":
				has_prank = true
		for c in cats:
			if int(cats[c]) > 2:
				bad.append("P%d 同类 %s 有 %d 张" % [pi, c, int(cats[c])])
		if not has_noise_or_decor:
			bad.append("P%d 没有 noise/decor" % pi)
		if not has_prank:
			bad.append("P%d 没有 prank" % pi)
	return bad


## 遍历所有两两组合，找出**行为集合相同**的玩家对（规则 6，集合口径：顺序无关）。
func _duplicate_hands(deal: Array) -> Array[String]:
	var bad: Array[String] = []
	for i in deal.size():
		for j in range(i + 1, deal.size()):
			if _set_key(deal[i]) == _set_key(deal[j]):
				bad.append("P%d 与 P%d 清单集合相同：%s" % [i, j, _set_key(deal[i])])
	return bad


## 清单的行为 id 集合（去重 + 排序，顺序无关）—— 规则 6 的集合口径。
func _set_key(list: Array) -> String:
	var ids: Array[String] = []
	for m in list:
		var id := String(m.id)
		if not ids.has(id):
			ids.append(id)
	ids.sort()
	return "|".join(ids)


## 造两份"行为集合相同、顺序不同"的清单（旧的逐位比较看不出这种撞车）。
func _fake_same_set_deal() -> Array:
	var a: Array[Mischief] = []
	var b: Array[Mischief] = []
	var ids := [&"steal_carrot", &"prank_pot", &"noise_pot"]
	for i in ids.size():
		var ma := Mischief.new()
		ma.id = ids[i]
		a.append(ma)
		var mb := Mischief.new()
		mb.id = ids[(i + 1) % ids.size()]
		b.append(mb)
	return [a, b]


## 违规列表的首条描述（用于失败诊断）。
func _first(bad: Array[String]) -> String:
	if bad.is_empty():
		return ""
	return " —— 违规 %d 处，例如：%s" % [bad.size(), bad[0]]


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
