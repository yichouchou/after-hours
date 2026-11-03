class_name GuardBrain
extends RefCounted

## 守卫的感知与状态机。纯逻辑：不引用任何场景树节点，
## 输入是"世界快照"字典，输出是"下一个状态"字典。
##
## update() 的 ctx 共 11 个键：
##   guard_pos / guard_facing / player_pos / player_visible / noise_pos / noise_active /
##   sight_range / sight_angle_deg / hearing_range / target_peer / light_factor
##
## player_visible 由场景层算好后传入（场景层用 in_sight_cone + effective_sight_range
## 判定）；本函数**不重算**可见性，否则会和 ctx 的判定打架。
## light_factor 的乘法只在 effective_sight_range 里做 —— 纯逻辑层不引入路灯实体，
## 几盏灯灭由场景层决定。

enum State { PATROL, SUSPICIOUS, CHASE, CARRY, RETURN }

const SUSPICION_GAIN := 2.0
const SUSPICION_DECAY := 1.0
const SUSPICION_THRESHOLD := 0.5
const CATCH_DISTANCE := 24.0
const SIGHT_ANGLE_DEFAULT := 80.0

var state: int = State.PATROL
var suspicion: float = 0.0
var target_peer: int = 0


## 目标是否落在守卫的视野锥形内。
## angle_deg 是**整个锥形的张角**，半角 = angle_deg * 0.5。
static func in_sight_cone(origin: Vector2, facing: Vector2, target: Vector2,
		sight_range: float, angle_deg: float) -> bool:
	if sight_range <= 0.0:
		return false
	var to := target - origin
	var dist := to.length()
	if dist > sight_range:
		return false
	if dist <= 0.0001:
		return true
	var f := facing.normalized()
	if f == Vector2.ZERO:
		return false
	var cos_a := cos(deg_to_rad(angle_deg * 0.5))
	return f.dot(to.normalized()) >= cos_a


## 光照衰减后的实际视野半径：base_range * clamp(light_factor, 0, 1)。
## light_factor = 1 全亮；每有一盏被熄灭的路灯覆盖到守卫，场景层乘 0.6。
static func effective_sight_range(base_range: float, light_factor: float) -> float:
	return maxf(0.0, base_range * clampf(light_factor, 0.0, 1.0))


## 声音是否在听觉范围内。hearing_range = 0 表示聋，永远够不到。
static func hearing_reached(dist: float, hearing_range: float) -> bool:
	return hearing_range > 0.0 and dist <= hearing_range


## 推进一帧状态机。返回 { state, target_peer, suspicion, catch_player }。
## 零失败惩罚：返回值里没有任何扣分 / 淘汰 / 扣命字段。
func update(delta: float, ctx: Dictionary) -> Dictionary:
	var player_pos: Vector2 = ctx.get("player_pos", Vector2.ZERO)
	var guard_pos: Vector2 = ctx.get("guard_pos", Vector2.ZERO)
	var facing: Vector2 = ctx.get("guard_facing", Vector2.RIGHT)
	var visible: bool = bool(ctx.get("player_visible", false))
	var noise_active: bool = bool(ctx.get("noise_active", false))
	var noise_pos: Vector2 = ctx.get("noise_pos", Vector2.ZERO)
	var hearing: float = float(ctx.get("hearing_range", 0.0))
	# 下面三个键由场景层用来算 player_visible，本函数只读取、不参与判定；
	# 前缀下划线表示"有意读取但不参与判定"，同时避免未使用变量告警。
	var _sight_range: float = float(ctx.get("sight_range", 100.0))
	var _sight_angle_deg: float = float(ctx.get("sight_angle_deg", SIGHT_ANGLE_DEFAULT))
	var _light_factor: float = float(ctx.get("light_factor", 1.0))

	var catch_player := false

	if visible:
		suspicion = minf(SUSPICION_THRESHOLD + 1.0, suspicion + SUSPICION_GAIN * delta)
		target_peer = int(ctx.get("target_peer", target_peer))
		state = State.CHASE
		if guard_pos.distance_to(player_pos) <= CATCH_DISTANCE:
			catch_player = true
	elif noise_active and hearing_reached(guard_pos.distance_to(noise_pos), hearing):
		suspicion = minf(SUSPICION_THRESHOLD, suspicion + SUSPICION_GAIN * delta)
		if state != State.CHASE:
			state = State.SUSPICIOUS
	else:
		suspicion = maxf(0.0, suspicion - SUSPICION_DECAY * delta)
		if suspicion <= 0.0 and state == State.SUSPICIOUS:
			state = State.PATROL

	return {
		"state": state,
		"target_peer": target_peer,
		"suspicion": suspicion,
		"catch_player": catch_player,
	}
