class_name MischiefDeck
extends RefCounted

## 捣蛋清单生成。纯函数：同样的输入永远得到同样的输出。
##
## 规则作用域（控制器裁决）：**每份清单各自成立**，不是整副牌一起成立。
##   1. 每人的牌数 N = clamp(player_count + 1, 3, 5)
##   2. 池子里只保留 target_tag 出现在 available_tags 中的行为
##   3. 同类（category）不超过 2
##   4. 至少 1 张 noise 或 decor
##   5. 至少 1 张 prank
##   6. 任意两份清单的**行为集合**都不相同（集合口径：顺序无关，即"不同的子集"）
##
## 跨玩家重叠契约：同一行为**可以**被多名玩家同时持有。P1 只有 10 条行为、
## 最多 6 名玩家，"整副牌不重复发牌"在 4-6 人局数学上不可实现。
## Task 10 的房主裁决按"先到先得"归属，落败方不扣分（零失败惩罚）。
##
## 池子确实不够时的契约：例如池子只有 1 张牌而每人要 3 张，数学上无法给出
## 两份不同的清单，此时允许重复（[carrot, carrot, carrot]），不返回空清单、不崩溃。

const CATEGORIES := [&"steal", &"mess", &"prank", &"decor", &"noise"]  # brief 自带的类别清单常量
const MAX_PER_CATEGORY := 2
const MAX_HAND_ATTEMPTS := 32  # 规则 6 兜底重抽次数上限（有界，保证不会死循环）


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

	# 规则 1/3/4/5/6：逐人成牌
	for i in player_count:
		deal[i] = _build_unique_hand(pool, n, rng, deal, i)

	return deal


## 给第 index 位玩家成一份 n 张的清单，并保证不与已发出的任何一份**行为集合**相同。
##
## 起点来源：每位玩家**独立**洗牌（消费 rng），再按 attempt 在整副牌上轮转起点。
## 候选因此覆盖全部 size 个起点 + 多种牌序，而不是只落在 (player_index * n) % size
## 那条等差数列上（那样 4-6 人局只能取到 2 个起点，多名玩家必然拿到同一份清单）。
static func _build_unique_hand(pool: Array[Mischief], n: int, rng: RandomNumberGenerator,
		deal: Array[Array], index: int) -> Array[Mischief]:
	# 池子里每个类别的牌都不超过 2 张时，任何一份清单都必然包含池子里**全部**的牌
	# （类别上限拦不下任何一张，补齐张数只会重复已有的牌）→ 可达的行为集合恒为 1 个，
	# 重抽也不可能给出不同的集合 → 直接返回，不白跑 32 次重抽。
	# （池子太小的既有契约保持不变：允许重复，不返回空清单、不崩溃。）
	if _single_set_only(pool):
		var only := pool.duplicate()
		_shuffle(only, rng)
		return _build_hand(only, n, 0)

	var hand: Array[Mischief] = []
	var tried := {}
	for attempt in MAX_HAND_ATTEMPTS:
		var deck := pool.duplicate()
		_shuffle(deck, rng)
		hand = _build_hand(deck, n, attempt % deck.size())
		if not _has_same(hand, deal, index):
			return hand
		tried[_set_key(hand)] = true
		# 候选集合已穷举：允许重复，返回当前这份
		if tried.size() >= _max_distinct_sets(pool.size(), n):
			break
	# 池子小到数学上无法给出两份不同的清单：允许重复，返回最后一份候选。
	return hand


## 从 deck 里按起点 start 取一份 n 张的清单。
static func _build_hand(deck: Array[Mischief], n: int, start: int) -> Array[Mischief]:
	var hand: Array[Mischief] = []
	var counts := {}
	var size := deck.size()
	if size == 0:
		return hand

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


## hand 是否和已发出的某份清单包含**相同的行为集合**（规则 6 集合口径：顺序无关）。
static func _has_same(hand: Array[Mischief], deal: Array[Array], dealt: int) -> bool:
	var key := _set_key(hand)
	for j in dealt:
		var other: Array = deal[j]
		if other.is_empty():
			continue
		if _set_key(other) == key:
			return true
	return false


## 清单的行为 id 集合（去重 + 排序，顺序无关）。规则 6 的比较口径。
static func _set_key(list: Array) -> String:
	var ids: Array[String] = []
	for m in list:
		var id := String(m.id)
		if not ids.has(id):
			ids.append(id)
	ids.sort()
	return "|".join(ids)


## 池子里每个类别的牌都不超过 2 张吗？
## 是的话，任何一份清单都必然包含池子里**全部**的牌（类别上限拦不下任何一张），
## 可达的"行为集合"恒为 1 个 → 规则 6 在这种池子上数学上不可满足。
static func _single_set_only(pool: Array[Mischief]) -> bool:
	var per_cat := {}
	for m in pool:
		var c: int = int(per_cat.get(m.category, 0)) + 1
		if c > MAX_PER_CATEGORY:
			return false
		per_cat[m.category] = c
	return true


## 池子能产生的不同"行为集合"数量的上界：Σ C(size, k)，k = 1..min(n, size)。
static func _max_distinct_sets(size: int, n: int) -> int:
	var total := 0
	var comb := 1
	for k in range(1, mini(n, size) + 1):
		comb = comb * (size - k + 1) / k
		total += comb
	return total


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
