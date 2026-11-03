class_name Rules
extends RefCounted

## 捣蛋裁决。纯函数：无状态、单次裁决。
##
## 设计约束（来自规格 §2 P1 零失败惩罚）：
##   * 返回值里**永远没有**扣分/扣命/淘汰字段
##   * "被抓"只是一个事件标记，由场景层用来把玩家送回出生点
##     （不扣分、不掉命、不淘汰、不清零进度）
##   * 缺搭档不阻断完成，只影响效率（效率倍率由交互层实现，本层不表达）
##
## evaluate(action, ctx) -> { "success": bool, "reason": String, "caught": bool }
##
## action 的键：
##   progress    float  捣蛋进度，达到 1.0 才算完成
##   peer_id / behavior_id / target_id
##               本层**不使用**。Rules 是无状态的单次裁决，只看 progress 和 ctx；
##               target_id 的归属裁决（同一目标被多人抢 → 先到先得）属于房主侧台账。
##
## ctx 的键（5 个键名是公开契约，缺键必须有缺省值）：
##   nearest_guard_distance  float  最近守卫距离，缺省 99999.0
##   guard_alerted           bool   守卫是否警觉，缺省 false
##   has_partner             bool   是否有搭档（不参与判定）
##   needs_partner           bool   行为是否需要搭档（不参与判定）
##   guard_catch_distance    float  抓捕判定半径，缺省 CATCH_DISTANCE(24.0)

## 抓捕判定半径。24 px ≈ 0.75 格（1 格 = 32 px），与 GuardBrain.CATCH_DISTANCE 同值。
const CATCH_DISTANCE := 24.0

## 最近守卫距离的缺省值：足够远，等价于"附近没有守卫"。
const NO_GUARD_NEAR_DISTANCE := 99999.0


## 裁决一次捣蛋行为。
## 返回值恰好 3 个键：success / reason / caught。
## reason 只有三个取值："in_progress"（进度不足）、"caught"（被抓）、"ok"（成功）。
static func evaluate(action: Dictionary, ctx: Dictionary) -> Dictionary:
	var progress: float = float(action.get("progress", 0.0))
	var nearest: float = float(ctx.get("nearest_guard_distance", NO_GUARD_NEAR_DISTANCE))
	var alerted: bool = bool(ctx.get("guard_alerted", false))
	var catch_dist: float = float(ctx.get("guard_catch_distance", CATCH_DISTANCE))
	# 下面两个键属于 ctx 的公开契约，本层读取但不参与任何判定：
	# 缺搭档只影响效率（交互层的 duration 倍率），不阻断完成。
	# 前缀下划线表示"有意读取但不参与判定"，同时避免未使用变量告警。
	var _has_partner: bool = bool(ctx.get("has_partner", false))
	var _needs_partner: bool = bool(ctx.get("needs_partner", false))

	if progress < 1.0:
		return {"success": false, "reason": "in_progress", "caught": false}

	var caught: bool = alerted and nearest <= catch_dist

	if caught:
		return {"success": false, "reason": "caught", "caught": true}

	# needs_partner / has_partner 仅为效率提示，不阻断
	return {"success": true, "reason": "ok", "caught": false}
