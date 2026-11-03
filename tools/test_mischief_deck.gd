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
	# 以下为 task-3 补充断言（brief 未覆盖）：可用行为不足时清单仍应有足够张数
	# ------------------------------------------------------------------

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


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
