extends SceneTree

## Task 8：玩家角色与拥有者权威同步 —— 单元测试。
##
## 覆盖派单 §4 的 14 条断言（下面每段注释标了 [§4-N]）。
## 另加少量补充断言（贴图取模、不得引用对局场景），不替代任何一条。

## player.gd 没有 class_name（避免占用全局类名，Task 11 可能还要用）→ 这里用 preload。
const PlayerScript := preload("res://scripts/player.gd")

const PLAYER_SCENE := "res://scenes/player.tscn"
const WORLD_MAP_SRC := "res://scripts/game/world_map.gd"
const PLAYER_SRC := "res://scripts/player.gd"

## 惩罚性 token（零失败惩罚）。口径与 tools/test_session.gd 保持一致。
const PENALTY_TOKENS := ["penalty", "penalized", "score", "score_delta",
	"lives", "lives_lost", "eliminated", "damage", "扣分", "扣命", "淘汰", "死亡"]

## 两字母的惩罚性 token 必须按**词边界**匹配：
## 子串扫会把任何恰好含有相邻字母的无关标识符误判成命中。
const PENALTY_WORD_TOKENS := ["hp"]

## char_0.png 的不透明像素包围盒**实测** = (35, 0, 92, 128)（128x128 画布，2x 素材）
## → 画布内 alpha 中心 x = 63.5、alpha 底边 = 128（= 画布高度）。
## 派单按包围盒 (14, 7, 51, 64) 估成 32.5，与实测差 0.5 px → 这里按**实测值**断言
## （判据比派单那条更严：|rect.x + 64.0| ≤ 2 同样覆盖 63.5）。
const ALPHA_CENTER_X := 64.0
const ALPHA_BOTTOM := 128.0

var _fails := 0
var _total := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	# ==================================================================
	# [§4-1] map.json 有 size；size == Vector2i(30, 18)
	# ==================================================================
	var map := WorldMap.load_map()
	_fails += _check(map.has("size"), "[§4-1] 地图有 size")
	_fails += _check(map.get("ok", false) == true,
		"[§4-1] 地图加载成功（ok == true），错误信息：%s" % str(map.get("error", "")))
	_fails += _check(map.get("size") == Vector2i(30, 18),
		"[§4-1] 地图尺寸是 30×18，实际 %s" % str(map.get("size")))

	# ==================================================================
	# [§4-2] 道具类型数 ≥ 6；含 carrot / lamp / pot / sign / dog
	# ==================================================================
	var props: Dictionary = map.get("props", {})
	_fails += _check(props.size() >= 6,
		"[§4-2] 地图至少有 6 类道具，实际 %d" % props.size())
	for tag in ["carrot", "lamp", "pot", "sign", "dog"]:
		_fails += _check(props.has(StringName(tag)), "[§4-2] 地图有 %s 道具" % tag)

	# ==================================================================
	# [§4-3] 跨文件不变量：mischief.json 里每条行为的 target_tag
	#         在地图上至少有 1 个点位
	# ==================================================================
	var mischief_all := Mischief.load_all()
	_fails += _check(mischief_all.size() > 0, "[§4-3] 捣蛋行为表非空")
	var missing_targets: Array[String] = []
	for m in mischief_all:
		var pts: Array = props.get(m.target_tag, [])
		if pts.is_empty():
			missing_targets.append("%s→%s" % [String(m.id), String(m.target_tag)])
	_fails += _check(missing_targets.is_empty(),
		"[§4-3] 每条行为的 target_tag 在地图上至少 1 个点位%s" % _first(missing_targets))

	# ==================================================================
	# [§4-4] dog 不是任何行为的 target_tag（纯装饰彩蛋）
	# ==================================================================
	var dog_is_target := false
	for m in mischief_all:
		if m.target_tag == &"dog":
			dog_is_target = true
	_fails += _check(not dog_is_target, "[§4-4] dog 不被任何捣蛋行为当作目标")

	# ==================================================================
	# [§6-补充] dog 只是装饰彩蛋：它进 available_tags **不改变**清单生成结果
	# （审查者实测：同 seed 下 MischiefDeck.generate 产出完全一致）
	# → 把"dog 只是装饰"这个语义钉死，防止以后有人给 dog 加行为。
	# ==================================================================
	var tags_no_dog: Array[StringName] = []
	for m2 in mischief_all:
		tags_no_dog.append(m2.target_tag)
	var tags_with_dog: Array[StringName] = []
	for m3 in mischief_all:
		tags_with_dog.append(m3.target_tag)
	tags_with_dog.append(&"dog")
	var rng_dog := RandomNumberGenerator.new()
	rng_dog.seed = 20261104
	var rng_nodog := RandomNumberGenerator.new()
	rng_nodog.seed = 20261104
	var deal_dog := MischiefDeck.generate(mischief_all, 4, rng_dog, tags_with_dog)
	var deal_nodog := MischiefDeck.generate(mischief_all, 4, rng_nodog, tags_no_dog)
	_fails += _check(_deal_key(deal_dog) == _deal_key(deal_nodog),
		"[§6-补充] dog 进 available_tags 不改变清单生成结果（同 seed → 同结果）")

	# ==================================================================
	# [§4-5] 所有道具点位都在地图范围内（0 ≤ x < 30，0 ≤ y < 18）
	#        返回的坐标是像素（格坐标 × TILE），这里换算回格坐标再比。
	# ==================================================================
	var size: Vector2i = map.get("size", Vector2i.ZERO)
	var out_of_range: Array[String] = []
	for tag in props.keys():
		for pos in props[tag]:
			var tx := int(pos.x / WorldMap.TILE)
			var ty := int(pos.y / WorldMap.TILE)
			if tx < 0 or ty < 0 or tx >= size.x or ty >= size.y:
				out_of_range.append("%s(%d,%d)" % [String(tag), tx, ty])
	_fails += _check(out_of_range.is_empty(),
		"[§4-5] 所有道具点位都在地图范围内%s" % _first(out_of_range))

	# ==================================================================
	# [§4-6] player.tscn 可 load() 且 instantiate() 不报错
	# ==================================================================
	var packed: PackedScene = load(PLAYER_SCENE)
	_fails += _check(packed != null, "[§4-6] player.tscn 可加载")
	var player = null
	if packed != null:
		player = packed.instantiate()
		_fails += _check(player != null, "[§4-6] player.tscn 可实例化")

	# ==================================================================
	# [§4-7] player.tscn 含 MultiplayerSynchronizer
	# ==================================================================
	var sync = null
	if player != null:
		sync = player.get_node_or_null("MultiplayerSynchronizer")
		_fails += _check(sync != null, "[§4-7] 玩家带 MultiplayerSynchronizer")
		_fails += _check(sync is MultiplayerSynchronizer,
			"[§4-7] MultiplayerSynchronizer 节点类型正确")

	# ==================================================================
	# [§4-8] replication_config 非 null；属性键是 NodePath(".:position")；
	#         开启 spawn 同步；同步模式是 ON_CHANGE
	# ==================================================================
	if sync != null:
		var cfg = sync.replication_config
		_fails += _check(cfg != null, "[§4-8] replication_config 非 null")
		if cfg != null:
			var prop := NodePath(".:position")
			_fails += _check(cfg.has_property(prop),
				"[§4-8] position 在同步属性里（键 = NodePath(\".:position\")）")
			_fails += _check(cfg.property_get_spawn(prop),
				"[§4-8] position 开启 spawn 同步")
			_fails += _check(
				cfg.property_get_replication_mode(prop)
					== SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE,
				"[§4-8] position 的同步模式是 ON_CHANGE（常量断言，不写死数字）")

			# ==================================================================
			# [§4-9] 反向自检：has_property(NodePath("position")) 必须为 false
			#        —— 证明 §4-8 那条不是恒真。
			#        （has_property 对不存在的路径不打引擎 ERROR，断言安全。）
			# ==================================================================
			_fails += _check(not cfg.has_property(NodePath("position")),
				"[§4-9] 反向自检：has_property(NodePath(\"position\")) 为 false")

	# ==================================================================
	# [§4-10] resolve_authority 纯函数解析
	# ==================================================================
	_fails += _check(PlayerScript.resolve_authority("1075349658") == 1075349658,
		"[§4-10] resolve_authority(\"1075349658\") == 1075349658")
	_fails += _check(PlayerScript.resolve_authority("not_a_number") == 1,
		"[§4-10] resolve_authority(\"not_a_number\") == 1（兜底）")
	_fails += _check(PlayerScript.resolve_authority("") == 1,
		"[§4-10] resolve_authority(\"\") == 1（兜底）")

	# ==================================================================
	# [§4-10-B] 非法输入必须兜底 1（修复轮 1 / F3 + F4）
	#
	# 旧实现只看 is_valid_int()，它是**纯字面**判断：
	#   "007" → 7（前导零被吞 → 与 "7" 撞车）
	#   "-5" → -5、"0" → 0 → set_multiplayer_authority() 收到非法 id，
	#        引擎**静默接受**（无 ERROR），但 is_multiplayer_authority() 恒为 false
	#        → **该玩家永远不响应输入**
	#   "99999999999999999999" → is_valid_int() 为 true，但 int() **溢出**
	#        → 打引擎 ERROR（Cannot represent … as a 64-bit signed integer）
	# 新规则：只接受 ^[1-9][0-9]{0,9}$ 且数值 ∈ [1, 2^31-1]，其余一律兜底 1。
	# ==================================================================
	for bad_name in ["007", "-5", "0", "+3", " 12", "2147483648",
			"99999999999999999999"]:
		_fails += _check(PlayerScript.resolve_authority(bad_name) == 1,
			"[§4-10-B] resolve_authority(\"%s\") == 1（非法输入兜底房主）" % bad_name)
	_fails += _check(PlayerScript.resolve_authority("2147483647") == 2147483647,
		"[§4-10-B] resolve_authority(\"2147483647\") == 2147483647（2^31-1 是上界）")
	_fails += _check(PlayerScript.resolve_authority("1") == 1,
		"[§4-10-B] resolve_authority(\"1\") == 1（最小合法值）")

	# ==================================================================
	# [§4-10-C] F4 自检：超长数字**不得**打出引擎 ERROR（溢出转换）
	#
	# "输出里没有 ERROR 行"没法在**本进程**内自察（引擎错误直接写 stderr）。
	# → 另起一个 Godot 子进程调用同一个 resolve_authority，把它的 stdout+stderr
	#   抓回来查 ERROR 行。探针写到 user://（不污染仓库），子进程用 --script user://… 跑。
	#   做法与 Task 7 的 test_session_link.gd 同款（OS.execute + read_stderr）。
	# ==================================================================
	var probe_path := "user://after_hours_task8_overflow_probe.gd"
	var probe_lines: Array[String] = [
		"extends SceneTree",
		"",
		"func _initialize() -> void:",
		"\tcall_deferred(\"_boot\")",
		"",
		"func _boot() -> void:",
		"\tvar P := load(\"res://scripts/player.gd\")",
		"\tprint(\"OVERFLOW|\", P.resolve_authority(\"99999999999999999999\"))",
		"\tquit(0)",
		"",
	]
	var probe_file := FileAccess.open(probe_path, FileAccess.WRITE)
	_fails += _check(probe_file != null,
		"[§4-10-C] 能在 user:// 写出溢出自检探针（%s）" % probe_path)
	if probe_file != null:
		probe_file.store_string("\n".join(probe_lines))
		probe_file.close()
		var child_out: Array = []
		var child_args := PackedStringArray([
			"--headless",
			"--path", ProjectSettings.globalize_path("res://"),
			"--quit-after", "120",
			"--script", probe_path,
		])
		var child_code := OS.execute(OS.get_executable_path(), child_args,
			child_out, true)
		var child_text := ""
		for chunk in child_out:
			child_text += str(chunk)
		var err_lines: Array[String] = []
		for line in child_text.split("\n"):
			if line.contains("ERROR"):
				err_lines.append(line.strip_edges())
		_fails += _check(child_code == 0,
			"[§4-10-C] 溢出自检子进程正常退出（实际 %d）" % child_code)
		_fails += _check(err_lines.is_empty(),
			"[§4-10-C] 超长数字**不产生**引擎 ERROR（子进程输出 0 行 ERROR）%s"
			% _first(err_lines))

	# ==================================================================
	# [§4-11] 实例化一个名字为 "1075349658" 的 Player 并加入树
	#         → get_multiplayer_authority() == 1075349658
	# ==================================================================
	var owned = null
	if packed != null:
		owned = packed.instantiate()
		owned.name = "1075349658"
		root.add_child(owned)
		await process_frame
		_fails += _check(owned.get_multiplayer_authority() == 1075349658,
			"[§4-11] 节点名 = peer id → 权威 = 1075349658，实际 %d"
			% owned.get_multiplayer_authority())

		# ==================================================================
		# [§4-12] 非权威方不写 position：权威不是自己时，
		#         _physics_process 不得改变 position / velocity
		# ==================================================================
		var pos_before = owned.position
		var vel_before = owned.velocity
		owned.call("_physics_process", 0.016)
		await physics_frame
		await physics_frame
		_fails += _check(owned.position == pos_before and owned.velocity == vel_before,
			"[§4-12] 非权威方 _physics_process 不改 position/velocity"
			+ "（position %s → %s，velocity %s → %s）"
			% [str(pos_before), str(owned.position), str(vel_before), str(owned.velocity)])

		# ==================================================================
		# [§4-12-B1/B2/B3] 权威守卫必须**可分辨**（修复轮 1 / F2）
		#
		# 上面那条 §4-12 在 headless 下**恒真**：没有输入 → dir = Vector2.ZERO
		# → 权威分支里 velocity.lerp(0) = 0 → move_and_slide() 无位移。
		# 它只能证明"非权威分支没写 position/velocity"，
		# **无法证明权威分支存在** —— 删掉守卫它照样 PASS（审查者的变异实验）。
		# 修法：**注入输入**（Input.action_press("ui_right")）+ 三段式：
		#   B1 权威是自己 + 注入输入 → 必须移动（正向对照：证明权威分支真在跑）
		#   B2 非权威     + 同样输入 → 必须不移动（证明守卫在拦）
		#   B3 权威是自己 + 同样输入 → 必须又移动（证明 B2 的"不动"由权威变化引起）
		# 每次用完必须 release，否则会污染后续断言。
		# ==================================================================
		var local_id: int = root.multiplayer.get_unique_id()
		owned.set_multiplayer_authority(local_id)
		_fails += _check(owned.is_multiplayer_authority(),
			"[§4-12-B1] 权威设成本地 id(%d) 后 is_multiplayer_authority() 为 true"
			% local_id)
		var b1_before: Vector2 = owned.position
		Input.action_press("ui_right")
		for i in 8:
			owned.call("_physics_process", 0.016)
			await physics_frame
		Input.action_release("ui_right")
		var b1_dist: float = owned.position.distance_to(b1_before)
		_fails += _check(b1_dist > 0.5,
			"[§4-12-B1] 权威是自己 + 注入 ui_right → 位置发生变化（位移 %.3f px）"
			% b1_dist)

		# B2：把权威换成**不是自己**的 id，注入同样的输入 → 必须一动不动
		owned.set_multiplayer_authority(local_id + 1)
		var b2_before: Vector2 = owned.position
		var b2_vel_before: Vector2 = owned.velocity
		Input.action_press("ui_right")
		for i in 8:
			owned.call("_physics_process", 0.016)
			await physics_frame
		Input.action_release("ui_right")
		_fails += _check(not owned.is_multiplayer_authority(),
			"[§4-12-B2] 权威换成非本地 id(%d) 后 is_multiplayer_authority() 为 false"
			% (local_id + 1))
		_fails += _check(owned.position == b2_before and owned.velocity == b2_vel_before,
			"[§4-12-B2] 非权威 + 同样的输入 → position/velocity 一动不动"
			+ "（position %s → %s，velocity %s → %s）"
			% [str(b2_before), str(owned.position), str(b2_vel_before), str(owned.velocity)])

		# B3：把权威还给自己 → 必须又能动（证明 B2 的"不动"确实由权威变化引起）
		owned.set_multiplayer_authority(local_id)
		var b3_before: Vector2 = owned.position
		Input.action_press("ui_right")
		for i in 8:
			owned.call("_physics_process", 0.016)
			await physics_frame
		Input.action_release("ui_right")
		var b3_dist: float = owned.position.distance_to(b3_before)
		_fails += _check(b3_dist > 0.5,
			"[§4-12-B3] 权威还给自己 + 注入 ui_right → 又能移动（位移 %.3f px）"
			% b3_dist)
		# 还原成与节点名一致的权威（peer id 约定）
		owned.set_multiplayer_authority(PlayerScript.resolve_authority(owned.name))

		# ==================================================================
		# [§4-12-C] ★ 远端化身随位置差左右翻转（B4）
		#
		# 背景：MultiplayerSynchronizer 只同步 ".:position"（player.tscn 的
		#   SceneReplicationConfig 只有一条属性），远端机器上 **velocity 恒为 0**
		#   → 拥有者分支那套「按 velocity.x 决定翻转」永远不触发
		#   → **别人的角色永远朝右**，往左走也是朝右（用户报障）。
		# 修法：非拥有者分支按「位置差 / delta」还原速度，复用同一个阈值。
		#
		# ★ 这里**手动改 position** 来模拟同步器把新位置推过来
		#   （headless 单进程里没有第二个 peer，真同步器跑不起来）。
		# ★ 每次断言前都**显式**把 flip_h 设成相反值 → 断言的是"翻转了"，
		#   不是"碰巧本来就是这个值"。
		# ==================================================================
		var remote_sprite = owned.get_node_or_null("Sprite2D") as Sprite2D
		_fails += _check(remote_sprite != null, "[§4-12-C] 远端化身能拿到 Sprite2D")
		if remote_sprite != null:
			_fails += _check(not owned.is_multiplayer_authority(),
				"[§4-12-C] 前提：权威不是自己（走非拥有者分支）")
			# 先调一次 → 让脚本把当前 position 记成基线（后面的位移才是干净的）
			var base_pos: Vector2 = owned.position
			owned.call("_physics_process", 0.016)

			# 往右挪 → 化身朝右（flip_h == false）
			remote_sprite.flip_h = true
			owned.position = base_pos + Vector2(40.0, 0.0)
			owned.call("_physics_process", 0.016)
			_fails += _check(remote_sprite.flip_h == false,
				"[§4-12-C] 远端化身往右走 → 面向右（flip_h == false）")

			# 往左挪 → 化身朝左（flip_h == true）
			remote_sprite.flip_h = false
			owned.position = base_pos + Vector2(-40.0, 0.0)
			owned.call("_physics_process", 0.016)
			_fails += _check(remote_sprite.flip_h == true,
				"[§4-12-C] 远端化身往左走 → 面向左（flip_h == true）")

			# 速度死区：几乎不动 → 保持上一次朝向（不抖）
			remote_sprite.flip_h = true
			owned.position = base_pos + Vector2(-39.95, 0.0)
			owned.call("_physics_process", 0.016)
			_fails += _check(remote_sprite.flip_h == true,
				"[§4-12-C] 远端化身几乎不动 → 保持上一次朝向（速度死区）")

			# 远端分支**不许**写 position / velocity（同步器才是位置的唯一来源）
			var rp_before: Vector2 = owned.position
			var rv_before: Vector2 = owned.velocity
			owned.call("_physics_process", 0.016)
			_fails += _check(owned.position == rp_before and owned.velocity == rv_before,
				"[§4-12-C] 远端分支不写 position/velocity（位置只由同步器给）"
				+ "（position %s → %s，velocity %s → %s）"
				% [str(rp_before), str(owned.position), str(rv_before), str(owned.velocity)])

		# ==================================================================
		# [F1] 贴图与碰撞体必须重合：脚底落在 y = 0，视觉中心基本居中。
		#
		# 背景：Sprite2D.centered 的默认值是 **true**，而场景里的
		# offset = (-32, -64) 是**按 centered = false 算出来的** ——
		# 没写 centered = false 时，绘制矩形 = Rect2(offset - size/2, size)
		# = (-64, -96, 64, 64)：角色脚底在 y = -32（**浮空 32 px**）、
		# 整体偏左半个身位，与碰撞体不重合。
		# 场景显式 centered = false 后：绘制矩形 = Rect2(-32, -64, 64, 64)。
		# ==================================================================
		var sprite = owned.get_node_or_null("Sprite2D")
		_fails += _check(sprite != null, "[F1] 玩家带 Sprite2D")
		if sprite != null:
			var rect: Rect2 = sprite.get_rect()
			_fails += _check(sprite.centered == false,
				"[F1] Sprite2D.centered == false（offset 按左上角语义算）")
			_fails += _check(rect.position.y + rect.size.y == 0.0,
				"[F1] 贴图绘制底落在地面 y = 0（rect %s）" % str(rect))
			_fails += _check(absf(rect.position.x + ALPHA_CENTER_X) <= 2.0,
				"[F1] 视觉中心基本居中（|rect.x + %.1f| ≤ 2，实测 %.3f）"
				% [ALPHA_CENTER_X, absf(rect.position.x + ALPHA_CENTER_X)])
			var bbox := _alpha_bbox(sprite.texture)
			_fails += _check(not bbox.is_empty(),
				"[F1] 能算出贴图的不透明像素包围盒")
			if not bbox.is_empty():
				var alpha_bottom: float = rect.position.y + float(bbox[3]) + 1.0
				var alpha_center_x: float = rect.position.x + (
						float(bbox[0]) + float(bbox[2])) * 0.5
				_fails += _check(absf(alpha_bottom) <= 0.001,
					"[F1] alpha 脚底落在地面 y = 0（局部实测 %.3f）" % alpha_bottom)
				_fails += _check(absf((float(bbox[3]) + 1.0) - ALPHA_BOTTOM) <= 0.001,
					"[F1] 不透明像素一直画到画布底边（画布内 %.1f）" % ALPHA_BOTTOM)
				_fails += _check(absf(alpha_center_x) <= 2.0,
					"[F1] alpha 视觉中心基本居中（实测局部 %.3f）" % alpha_center_x)
			var col = owned.get_node_or_null("CollisionShape2D")
			_fails += _check(col != null, "[F1] 玩家带 CollisionShape2D")
			if col != null and col.shape is RectangleShape2D:
				var col_bottom: float = col.position.y + (
						col.shape as RectangleShape2D).size.y * 0.5
				_fails += _check(absf(col_bottom - (rect.position.y + rect.size.y)) <= 0.001,
					"[F1] 碰撞体底 == 贴图脚底（碰撞 %.1f / 贴图 %.1f）"
					% [col_bottom, rect.position.y + rect.size.y])

		# 补充：贴图索引用 posmod —— player_index = -1 应落到 char_5
		var neg = packed.instantiate()
		neg.name = "1075349659"
		neg.set("player_index", -1)
		root.add_child(neg)
		await process_frame
		var neg_sprite = neg.get_node_or_null("Sprite2D")
		_fails += _check(neg_sprite != null and neg_sprite.texture != null
				and neg_sprite.texture.resource_path.ends_with("char_5.png"),
			"[补充] player_index = -1 → 贴图走 posmod 落到 char_5.png")
		neg.queue_free()

	# ==================================================================
	# [§4-13] 纯净化：world_map.gd 不碰场景树；两个文件都不调 Steam.；
	#         两个文件都不出现惩罚性 token
	# ==================================================================
	var wm_src := _read_source(WORLD_MAP_SRC)
	var pl_src := _read_source(PLAYER_SRC)
	_fails += _check(not wm_src.is_empty(), "[§4-13] world_map.gd 可读")
	_fails += _check(not pl_src.is_empty(), "[§4-13] player.gd 可读")
	_fails += _check(not wm_src.contains("get_tree("),
		"[§4-13] world_map.gd 不出现 get_tree(")
	_fails += _check(not wm_src.contains("get_node("),
		"[§4-13] world_map.gd 不出现 get_node(")
	_fails += _check(not pl_src.contains("Steam."), "[§4-13] player.gd 不出现 Steam. 调用")
	_fails += _check(not wm_src.contains("Steam."), "[§4-13] world_map.gd 不出现 Steam. 调用")
	for token in PENALTY_TOKENS:
		_fails += _check(not pl_src.contains(token),
			"[§4-13] player.gd 不出现惩罚性 token「%s」" % token)
		_fails += _check(not wm_src.contains(token),
			"[§4-13] world_map.gd 不出现惩罚性 token「%s」" % token)
	for token in PENALTY_WORD_TOKENS:
		_fails += _check(not _has_word(pl_src, token),
			"[§4-13] player.gd 不出现惩罚性 token「%s」（独立词）" % token)
		_fails += _check(not _has_word(wm_src, token),
			"[§4-13] world_map.gd 不出现惩罚性 token「%s」（独立词）" % token)
	# 补充：本任务不得引用对局场景（那是 Task 11 的东西）
	_fails += _check(not pl_src.contains("scenes/game.tscn"),
		"[补充] player.gd 不引用 scenes/game.tscn")
	_fails += _check(not wm_src.contains("scenes/game.tscn"),
		"[补充] world_map.gd 不引用 scenes/game.tscn")

	# ==================================================================
	# [§4-14] load_map 对不存在的路径 / 非法 JSON 的返回必须自洽（不抛异常）
	# ==================================================================
	var missing := WorldMap.load_map("res://data/does_not_exist_map.json")
	_fails += _check(missing.get("ok", false) == false,
		"[§4-14] 不存在的路径 → ok == false")
	_fails += _check(missing.get("size") == Vector2i.ZERO,
		"[§4-14] 不存在的路径 → size 是零值（不是看起来正常的地图）")
	_fails += _check((missing.get("props", {}) as Dictionary).is_empty(),
		"[§4-14] 不存在的路径 → props 为空")
	_fails += _check(str(missing.get("error", "")) != "",
		"[§4-14] 不存在的路径 → 带有失败原因")

	var bad_path := "user://after_hours_task8_invalid_map.json"
	var bad_file := FileAccess.open(bad_path, FileAccess.WRITE)
	if bad_file != null:
		bad_file.store_string("{ 这不是合法 JSON ")
		bad_file.close()
		var bad := WorldMap.load_map(bad_path)
		_fails += _check(bad.get("ok", false) == false,
			"[§4-14] 非法 JSON → ok == false")
		_fails += _check(bad.get("size") == Vector2i.ZERO,
			"[§4-14] 非法 JSON → size 是零值")
		_fails += _check((bad.get("props", {}) as Dictionary).is_empty(),
			"[§4-14] 非法 JSON → props 为空")
	else:
		_fails += _check(false, "[§4-14] 能在 user:// 写出坏 JSON 样本")

	# ------------------------------------------------------------------
	# 收尾：释放实例
	# ------------------------------------------------------------------
	if owned != null:
		owned.queue_free()
	if player != null:
		player.free()
	await process_frame

	print("")
	print("断言总数: %d" % _total)
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


## 读源码（纯文本）。
func _read_source(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


## 贴图不透明像素的包围盒 [minx, miny, maxx, maxy]（整张透明 → 空数组）。
##
## 用来把"角色脚底在哪 / 视觉中心在哪"从**肉眼**变成**可断言的数字**。
func _alpha_bbox(tex: Texture2D) -> Array:
	if tex == null:
		return []
	var img := tex.get_image()
	if img == null:
		return []
	if img.is_compressed():
		img.decompress()
	var minx := 9999
	var miny := 9999
	var maxx := -1
	var maxy := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				minx = mini(minx, x)
				miny = mini(miny, y)
				maxx = maxi(maxx, x)
				maxy = maxi(maxy, y)
	if maxx < 0:
		return []
	return [minx, miny, maxx, maxy]


## 整副清单的可比键：每份清单的行为 id 集合（排序后用 "|" 连接），份与份之间用 ";" 连接。
func _deal_key(deal: Array) -> String:
	var parts: Array[String] = []
	for hand in deal:
		var ids: Array[String] = []
		for m in hand:
			ids.append(String(m.id))
		ids.sort()
		parts.append("|".join(ids))
	return ";".join(parts)


## 源码里有没有出现「作为一个独立词」的 token（**词边界匹配**）。
## 正则编译失败时退回子串匹配（宁可多报，不可漏报）。
func _has_word(src: String, token: String) -> bool:
	var re := RegEx.new()
	if re.compile("\\b%s\\b" % token) != OK:
		return src.contains(token)
	return re.search(src) != null


## 违规列表的首条描述（用于失败诊断）。
func _first(bad: Array) -> String:
	if bad.is_empty():
		return ""
	return " —— 违规 %d 处，例如：%s" % [bad.size(), str(bad[0])]


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
