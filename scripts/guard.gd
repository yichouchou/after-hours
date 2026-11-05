extends Node2D

## 守卫实体。把场景信息喂给纯逻辑的 GuardBrain，再按结果驱动表现。
## AI 逻辑只在房主跑（权威在房主），这里不做任何联机判定。
##
## 场景层的两项职责（大脑不重算，Task 4 的裁决）：
##   * player_visible：用 GuardBrain.in_sight_cone + GuardBrain.effective_sight_range
##     自己算出来再喂进 ctx —— 否则守卫会在全黑环境里照样追击，
##     「拔路灯」这条核心玩法就废了。
##   * light_factor：用 GuardBrain.compute_light_factor() 按注入的灯列表算
##     （每盏熄灭的路灯 -40% 视野）。灯的状态由 Task 10 置为熄灭。
##
## 注入方式（**不许**硬编码场景路径，场景节点之间不要用绝对路径互相引用）：
##   * player_root：玩家容器节点（set_player_root / 直接赋值）
##   * lamp_root  ：路灯容器节点（set_lamp_root）
##   * rpc        ：scripts/net/game_rpc.gd 的实例（set_rpc）
##
## 押送链路的分工（Task 9 裁决）：
##   房主（本脚本）：抓到 → brain.begin_carry() → 广播 player_caught →
##     朝被抓玩家移动（做出「押着走」的表演）→ 收到 escort_finished →
##     brain.finish_carry() → 走回岗位 → 回到巡逻。
##   客户端：只按 guard_state 广播更新**表现**位置，不跑 AI。
##   ★ 房主**不许**直接写玩家的 position（玩家位置是拥有者权威），
##     「送回出生点」由被抓玩家自己走（scripts/player.gd）。

signal spotted(peer_id: int)
signal caught_player(peer_id: int)

## 数据 id（来自 data/guards.json 的 "id" 字段）。
@export var guard_id: StringName = &"old_chen"

## 线上用的**数字**守卫 id（设计 §5.3 的 RPC 载荷是 int）。
## 与上面的 guard_id（StringName，数据标识）不是一回事：一个是网络寻址编号，
## 一个是角色标识。P1 只有 1 个守卫 → 1。
@export var guard_wire_id: int = 1

@export var patrol_radius: float = 120.0
@export var sight_range: float = 96.0
@export var sight_angle_deg: float = 80.0
@export var hearing_range: float = 128.0
@export var speed: float = 70.0

## 显式巡逻点（设计 §9）。**非空就按顺序走这些点**（走到最后回到第一个）；
## 空则沿用计划里的「绕家转圈的圆形巡逻」（计划的行为不变）。
@export var patrol_points: Array[Vector2] = []

## 回到岗位的判定容差（px）。
const HOME_TOLERANCE := 6.0

## 走到一个巡逻点的判定容差（px）。
const PATROL_POINT_TOLERANCE := 4.0

## 广播守卫状态的间隔（秒）。守卫只跑在房主，广播只是给客户端看表现。
const STATE_BROADCAST_INTERVAL := 0.05

## 朝向翻转的判定阈值：朝向向量在 x 轴上的投影（cos(facing_angle)）。
## |投影| ≤ 阈值 → 正在上下走 / 转身中 → 保持上一次朝向。
const FLIP_FACING_THRESHOLD := 0.35

@onready var sprite: Sprite2D = $Sprite2D

## 由游戏场景注入的玩家容器（运行时注入，**不**硬编码路径）。
var player_root: Node2D = null

## 由游戏场景注入的路灯容器（运行时注入，**不**硬编码路径）。
var lamp_root: Node2D = null

## 由游戏场景注入的 RPC 节点（scripts/net/game_rpc.gd 的实例）。
var rpc: Node = null

var brain: GuardBrain = GuardBrain.new()

## 朝向（弧度，0 = 朝右）。
##
## ★ 为什么不直接用节点的 rotation：
##   节点一旋转，贴图连同 offset(-32,-64) 一起转 →
##   人物会**绕着自己的脚底翻过去**（侧躺着，像具尸体；
##   2026-11-04 用户截图里的老陈就是这个样子）。
##   而且客户端那个守卫靠广播更新位置、**根本不转** → 两端长得都不一样。
##   → 节点永远不转，朝向单独记在这儿；视野锥照旧用它算。
## ★ 将来换成真美术（角色有左右朝向）时，在这里加「朝左就水平翻转贴图」即可，
##   仍然不要去转节点。
var facing_angle: float = 0.0

var _home := Vector2.ZERO
var _patrol_angle := 0.0
var _patrol_point_index := 0
var _target_position := Vector2.ZERO
## 押送结束后正在走回岗位（这段路上不跑 AI，只走回家）。
var _returning_home := false
## 直接注入的灯列表（元素形如 {"position": Vector2, "on": bool}）。
var _injected_lamps: Array = []
var _broadcast_accum := 0.0
## 听到的动静发生在哪（世界坐标）。
var _noise_pos := Vector2.ZERO
## 动静还能被听见多久（秒）；≤ 0 = 已经听不见了。
var _noise_timer := 0.0


func _ready() -> void:
	_home = global_position
	_patrol_angle = randf() * TAU
	# 只有房主跑 AI；客户端靠 guard_state 广播更新表现位置。
	# ★ 用 PeerState 而不是 multiplayer.is_server()：mp 上没有 peer 时
	#   is_server() 会打引擎 ERROR 并恒返回 false → 守卫 AI 整场停摆
	#   （2026-11-04 用户报障）。
	set_physics_process(PeerState.is_local_host(multiplayer))


func _physics_process(delta: float) -> void:
	if not PeerState.is_local_host(multiplayer):
		return

	# 动静会衰减：听见一阵就忘了（不然守卫会一直记着那一嗓子）。
	if _noise_timer > 0.0:
		_noise_timer = maxf(0.0, _noise_timer - delta)

	var st := brain.state
	if _returning_home:
		# 回岗位：只走路，不跑感知（大脑的 RETURN → PATROL 迁移由场景层收尾）。
		_walk_home(delta)
		st = brain.state
	else:
		var ctx := _sense_context()
		var result := brain.update(delta, ctx)
		st = int(result["state"])
		match st:
			GuardBrain.State.PATROL:
				_patrol(delta)
			GuardBrain.State.SUSPICIOUS:
				# ★ 听到动静 → 朝**声音传来的方向**走过去看看。
				#   不指方向的话，守卫只是"心里起疑"却站在原地，敲锅等于白敲。
				if _noise_timer > 0.0:
					_target_position = _noise_pos
				_move_towards(_target_position, delta)
			GuardBrain.State.CHASE:
				var tp := _player_position(int(result["target_peer"]))
				if tp != Vector2.ZERO:
					_target_position = tp
					spotted.emit(int(result["target_peer"]))
				_move_towards(_target_position, delta)
				if bool(result["catch_player"]):
					caught_player.emit(int(result["target_peer"]))
					brain.begin_carry()
					_broadcast_caught(int(result["target_peer"]))
			GuardBrain.State.CARRY:
				# 押送表演：朝被抓的玩家走（做出「押着走」的样子）。
				_follow_carried(delta)
			GuardBrain.State.RETURN:
				_returning_home = true
				_walk_home(delta)

	# 广播的是**当前**的 brain.state —— 不能用上面那个 st：
	# st 是 update() 刚返回时的快照，而本帧里 begin_carry() 可能已经把状态
	# 改成了 CARRY。用旧值广播 → 房主本地收到自己的广播 → 把状态又改回去。
	_broadcast_state(brain.state, delta)


## 朝向决定贴图左右翻转。
##
## ★ 只改 sprite.flip_h，**绝不改节点 rotation** ——
##   节点一转，贴图连同 offset 一起转，人物就绕着脚底翻倒了（见 facing_angle 的说明）。
## 判定用朝向向量在 x 轴上的投影：facing = Vector2.RIGHT.rotated(facing_angle)
## → facing.x = cos(facing_angle)；投影为负（朝左）才翻。
##
## 放在 _process 而不是 _physics_process：客户端那个守卫不跑 AI（只按广播更新位置），
## 但它也有 facing_angle —— _process 两端都会跑，翻转逻辑两端一致。
func _process(_delta: float) -> void:
	var face_x := cos(facing_angle)
	if face_x < -FLIP_FACING_THRESHOLD:
		sprite.flip_h = true
	elif face_x > FLIP_FACING_THRESHOLD:
		sprite.flip_h = false


## 组装给纯逻辑用的"世界快照"。
##
## 场景层负责算 player_visible（大脑只信任 ctx，不重算）与 light_factor。
## 找不到玩家就返回安全的空快照。
func _sense_context() -> Dictionary:
	var light := _light_factor()
	var facing := Vector2.RIGHT.rotated(facing_angle)
	var sight_now := GuardBrain.effective_sight_range(sight_range, light)
	var nearest := 99999.0
	var visible := false
	var target_peer := 0
	var player_pos := Vector2.ZERO

	if player_root != null:
		for child in player_root.get_children():
			var n2d := child as Node2D
			if n2d == null:
				continue
			var d := global_position.distance_to(n2d.global_position)
			if d < nearest:
				nearest = d
				player_pos = n2d.global_position
				target_peer = int(child.name) if child.name.is_valid_int() else 1
			if GuardBrain.in_sight_cone(global_position, facing, n2d.global_position,
					sight_now, sight_angle_deg):
				visible = true

	return {
		"guard_pos": global_position,
		"guard_facing": facing,
		"player_pos": player_pos,
		"player_visible": visible,
		"noise_pos": _noise_pos,
		"noise_active": _noise_timer > 0.0,
		"sight_range": sight_range,
		"sight_angle_deg": sight_angle_deg,
		"hearing_range": hearing_range,
		"target_peer": target_peer,
		"light_factor": light,
	}


## 场景层的光照因子：每盏熄灭的路灯在 5 格（160 px）内 → 视野 × 0.6。
func _light_factor() -> float:
	return GuardBrain.compute_light_factor(global_position, _lamp_states(),
		GuardBrain.DARK_LAMP_RADIUS)


## 灯列表：[{ "position": Vector2, "on": bool }]。
## 来源 = 直接注入的数组 + lamp_root 下的子节点。
## 灯是否亮着：**先看 meta "lamp_on"**，没有再看节点上的 lamp_on 属性，都没有就当亮着。
## （★ 顺序不能反：Task 9/10 定的**唯一**写入入口是 Interaction.set_lamp_on()，
##   它只写 meta "lamp_on"；属性那条是兼容老写法的兜底。）
func _lamp_states() -> Array:
	var out: Array = []
	out.append_array(_injected_lamps)
	if lamp_root == null:
		return out
	for child in lamp_root.get_children():
		var n2d := child as Node2D
		if n2d == null:
			continue
		out.append({"position": n2d.global_position, "on": _lamp_is_on(n2d)})
	return out


## 这盏灯亮着吗？亮着 → true。读取路径收口到 Interaction.is_lamp_on()。
func _lamp_is_on(n: Node) -> bool:
	return Interaction.is_lamp_on(n)


## 注入玩家容器。
func set_player_root(node: Node2D) -> void:
	player_root = node


## 房主：世界里某处**制造了动静**（敲锅之类）→ 告诉守卫「那边有声音」。
##
## ★ 这条通道是「制造噪音」这类行为**唯一**能惊动守卫的入口：
##   大脑（scripts/game/guard_brain.gd）从 Task 4 起就支持 ctx 的
##   noise_pos / noise_active（听觉分支 → 怀疑度上升 → SUSPICIOUS），
##   但场景层一直写死「noise_active = false」
##   → 「敲响酒馆的锅」这张牌**根本不会**惊动老陈（用户报障）。
## ★ 只有**房主**跑这套（守卫 AI 是房主权威）；
##   客户端靠 guard_state 广播看表现，不自己判。
## ★ duration = 动静还能被听见多久（秒）；过了就衰减掉。
func hear_noise(pos: Vector2, duration: float) -> void:
	_noise_pos = pos
	_noise_timer = maxf(duration, 0.0)


## 注入路灯容器（Task 10 把灯拔掉时改它们的 lamp_on / meta "lamp_on"）。
func set_lamp_root(node: Node2D) -> void:
	lamp_root = node


## 直接注入灯列表（元素形如 {"position": Vector2, "on": bool}）。
func set_lamps(lamps: Array) -> void:
	_injected_lamps = lamps.duplicate(true)


## 注入 RPC 节点并接上信号。
func set_rpc(node: Node) -> void:
	rpc = node
	if node == null:
		return
	_connect_signal(node, &"escort_completed_evt", _on_escort_completed_evt)
	_connect_signal(node, &"guard_state_evt", _on_guard_state_evt)


## 接信号（已接过就跳过，避免 "Signal already connected"）。
func _connect_signal(node: Node, sig: StringName, cb: Callable) -> void:
	if not node.has_signal(sig):
		return
	if node.is_connected(sig, cb):
		return
	node.connect(sig, cb)


## 房主：被抓玩家回报「已走回出生点」→ 结束押送，走回岗位。
func _on_escort_completed_evt(peer_id: int) -> void:
	if peer_id != brain.target_peer:
		return
	brain.finish_carry()
	_returning_home = true


## 客户端：按房主广播的守卫状态更新**表现**（不跑 AI）。
func _on_guard_state_evt(guard_id: int, state: int, position: Vector2,
		target_peer: int) -> void:
	if guard_id != guard_wire_id:
		return
	global_position = position
	brain.state = state
	brain.target_peer = target_peer


## 房主：把「抓到了某人」告诉所有人（设计协议 player_caught）。
func _broadcast_caught(peer_id: int) -> void:
	if rpc == null or not rpc.has_method("broadcast_player_caught"):
		return
	rpc.broadcast_player_caught(peer_id, guard_wire_id)


## 广播守卫的状态与位置（房主 → 所有人）。
func _broadcast_state(st: int, delta: float) -> void:
	_broadcast_accum += delta
	if _broadcast_accum < STATE_BROADCAST_INTERVAL:
		return
	_broadcast_accum = 0.0
	if rpc == null or not rpc.has_method("broadcast_guard_state"):
		return
	rpc.broadcast_guard_state(guard_wire_id, st, global_position, brain.target_peer)


## 押送表演：朝被抓的玩家走。
func _follow_carried(delta: float) -> void:
	var tp := _player_position(brain.target_peer)
	if tp != Vector2.ZERO:
		_target_position = tp
		_move_towards(_target_position, delta)


## 走回岗位。到了就把状态切回巡逻。
func _walk_home(delta: float) -> void:
	_move_towards(_home, delta)
	_face_towards(_home, delta)
	if global_position.distance_to(_home) <= HOME_TOLERANCE:
		_returning_home = false
		brain.state = GuardBrain.State.PATROL


## 巡逻。显式巡逻点非空 → 按顺序走这些点；否则绕家转圈。
func _patrol(delta: float) -> void:
	if not patrol_points.is_empty():
		var count := patrol_points.size()
		_patrol_point_index = posmod(_patrol_point_index, count)
		var target: Vector2 = patrol_points[_patrol_point_index]
		_move_towards(target, delta)
		_face_towards(target, delta)
		if global_position.distance_to(target) <= PATROL_POINT_TOLERANCE:
			_patrol_point_index = (_patrol_point_index + 1) % count
		return
	_patrol_angle += delta * 0.35
	var target := _home + Vector2(cos(_patrol_angle), sin(_patrol_angle * 0.7)) * patrol_radius
	_move_towards(target, delta)
	_face_towards(target, delta)


## 把朝向转向某个目标（平滑）。
##
## ★ 只改 facing_angle，**绝不改节点的 rotation** ——
##   节点一转，贴图连同 offset 一起转，人物就绕着脚底翻倒了（见 facing_angle 的说明）。
func _face_towards(target: Vector2, delta: float) -> void:
	facing_angle = lerp_angle(facing_angle, (target - global_position).angle(), 4.0 * delta)


## 往目标点走。
func _move_towards(target: Vector2, delta: float) -> void:
	var dir := target - global_position
	if dir.length() < 1.0:
		return
	global_position += dir.normalized() * speed * delta


## 某个 peer id 的玩家在哪（玩家容器按 peer id 命名）。
func _player_position(peer_id: int) -> Vector2:
	if player_root == null:
		return Vector2.ZERO
	var n := player_root.get_node_or_null(str(peer_id)) as Node2D
	return Vector2.ZERO if n == null else n.global_position
