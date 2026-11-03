class_name MischiefDeck
extends RefCounted

## 捣蛋清单生成。纯函数：同样的输入永远得到同样的输出。
##
## 规则（每份清单各自成立，不是整副牌一起成立）：
##   1. 每人的牌数 N = clamp(player_count + 1, 3, 5)
##   2. 池子里只保留 target_tag 出现在 available_tags 中的行为
##   3. 同类（category）不超过 2
##   4. 至少 1 张 noise 或 decor
##   5. 至少 1 张 prank
##   6. 不同玩家拿到不同子集

const CATEGORIES := [&"steal", &"mess", &"prank", &"decor", &"noise"]
const MAX_PER_CATEGORY := 2


## 返回每人一张牌数组，长度 = player_count。
##
## 注意返回类型用的是 Array[Array] 而不是 Array[Array[Mischief]]：
## Godot 4.7.2 的 GDScript 不支持嵌套带类型数组（解析期直接报
## "Nested typed collections are not supported."），元素类型只能退到内层无类型数组。
static func generate(all: Array[Mischief], player_count: int,
		rng: RandomNumberGenerator, available_tags: Array[StringName]) -> Array[Array]:
	var deal: Array[Array] = []
	for i in player_count:
		deal.append([] as Array[Mischief])
	if player_count <= 0 or all.is_empty():
		return deal

	var n: int = clampi(player_count + 1, 3, 5)

	# 规则 2：目标必须存在于本局地图
	var pool: Array[Mischief] = []
	for m in all:
		if available_tags.has(m.target_tag):
			pool.append(m)
	if pool.is_empty():
		return deal

	# 一份洗好的公共牌序：各玩家从不同起点取牌 → 拿到的是不同子集
	var deck := pool.duplicate()
	_shuffle(deck, rng)

	# 规则 1/3/4/5/6：逐人成牌
	for i in player_count:
		deal[i] = _build_hand(deck, n, i)
		# 规则 6：万一和别人的清单撞了，换个起点重建（池子只有一张牌时无法避免）
		var guard := 0
		while guard < deck.size() and _has_same(deal[i], deal, i):
			guard += 1
			deal[i] = _build_hand(deck, n, i + guard)

	return deal


## 给第 player_index 位玩家成一份 n 张的清单。
static func _build_hand(deck: Array[Mischief], n: int, player_index: int) -> Array[Mischief]:
	var hand: Array[Mischief] = []
	var counts := {}
	var size := deck.size()
	if size == 0:
		return hand
	var start := (player_index * n) % size

	# 规则 4/5：保底。先放 noise/decor 与 prank（池子里没有就跳过），
	# 保证这一步之后 counts 每类最多 1 张，规则 3 仍然守得住。
	_ensure_category(hand, deck, [&"noise", &"decor"], counts, start)
	_ensure_category(hand, deck, [&"prank"], counts, start)

	# 规则 3：同类不超过 2，按轮转顺序取牌
	for step in size:
		if hand.size() >= n:
			break
		var m: Mischief = deck[(start + step) % size]
		if hand.has(m):
			continue
		var c: int = int(counts.get(m.category, 0))
		if c >= MAX_PER_CATEGORY:
			continue
		hand.append(m)
		counts[m.category] = c + 1

	# 可用牌不够撑满 n 张时：用尽所有可用牌（此时放宽规则 3）
	for step in size:
		if hand.size() >= n:
			break
		var m: Mischief = deck[(start + step) % size]
		if hand.has(m):
			continue
		hand.append(m)
		counts[m.category] = int(counts.get(m.category, 0)) + 1

	# 可用牌连一份清单都填不满时：允许重复同一张，保证每人张数仍达标
	while hand.size() < n:
		hand.append(deck[start % size])

	return hand


## 保证 hand 里有 cats 里至少一种类别的牌（池子里有才加）。
static func _ensure_category(hand: Array[Mischief], deck: Array[Mischief], cats: Array[StringName],
		counts: Dictionary, start: int) -> void:
	for c in cats:
		var has := false
		for m in hand:
			if m.category == c:
				has = true
				break
		if has:
			continue
		for step in deck.size():
			var m: Mischief = deck[(start + step) % deck.size()]
			if m.category == c:
				hand.append(m)
				counts[m.category] = int(counts.get(m.category, 0)) + 1
				return


## hand 是否和已发出的某份清单完全一样。dealt 是已发出的份数（只看前面那几份）。
static func _has_same(hand: Array[Mischief], deal: Array[Array], dealt: int) -> bool:
	for j in dealt:
		var other: Array = deal[j]
		if other.is_empty() or other.size() != hand.size():
			continue
		var same := true
		for i in hand.size():
			if hand[i].id != other[i].id:
				same = false
				break
		if same:
			return true
	return false


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
