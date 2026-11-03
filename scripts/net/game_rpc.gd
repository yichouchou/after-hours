extends Node

## 对局期的 RPC 承载节点（房主 ↔ 客户端）。
##
## 本文件由 **Task 9** 创建（计划有洞：Task 11 引用了它却没人建），
## 承载「被抓 → 押送 → 送回自己的出生点」这条链路需要的三个 RPC：
##
##   房主 → 所有人：player_caught(peer_id, guard_id)
##   房主 → 所有人：guard_state(guard_id, state, position, target_peer)
##   客户端 → 房主：escort_finished(peer_id)        ← 控制器补充的回执
##
## 名字与签名照设计文档 §5.3 的 RPC 协议走，不要自造。
##
## ★ Task 10 会在**同一个文件**里追加 submit_mischief / resolve_mischief
##   —— **不要动**本任务交付的三个方法。
##
## 载荷全是**纯数据**（int / float / Vector2）：
## 没有 StringName、没有 Resource、没有对象引用
## （Task 7 的教训：Resource 作 RPC 载荷在客户端读不出字段）。

## 房主的 peer id 恒为 1（ENet server-relay）。
const HOST_PEER_ID := 1

## 「这个玩家被守卫抓了」（房主 → 所有人）。
## 名字带 _evt 后缀是为了不和同名 RPC 方法 player_caught 抢标识符。
signal caught_player_evt(peer_id: int, guard_id: int)

## 「守卫的状态与位置」（房主 → 所有人）。客户端据此更新**表现**位置，不跑 AI。
signal guard_state_evt(guard_id: int, state: int, position: Vector2, target_peer: int)

## 「被抓玩家已走回自己的出生点」（客户端 → 房主）。
signal escort_completed_evt(peer_id: int)


## 房主 → 所有人：这个玩家被守卫抓了（进入押送）。
@rpc("authority", "call_local", "reliable")
func player_caught(peer_id: int, guard_id: int) -> void:
	caught_player_evt.emit(peer_id, guard_id)


## 房主 → 所有人：守卫的状态与位置。
## 客户端据此更新本地守卫节点的**表现**位置（客户端不跑 AI）。
@rpc("authority", "call_local", "reliable")
func guard_state(guard_id: int, state: int, position: Vector2, target_peer: int) -> void:
	guard_state_evt.emit(guard_id, state, position, target_peer)


## 客户端 → 房主：被抓玩家已走回自己的出生点。
@rpc("any_peer", "call_remote", "reliable")
func escort_finished(peer_id: int) -> void:
	escort_completed_evt.emit(peer_id)


## 房主侧：广播「玩家被抓」。
##
## 直接用 .rpc()：注解是 "call_local" → **本地也会执行**（房主自己被抓也要生效），
## 同时发给所有远端客户端。实测（4.7.2）：离线（无 peer）时 .rpc() 只本地执行、
## 不报任何引擎 ERROR。
func broadcast_player_caught(peer_id: int, guard_id: int) -> void:
	player_caught.rpc(peer_id, guard_id)


## 房主侧：广播守卫的状态与位置。
func broadcast_guard_state(guard_id: int, state: int, position: Vector2,
		target_peer: int) -> void:
	guard_state.rpc(guard_id, state, position, target_peer)


## 被抓玩家侧：向房主回报「我已经走回自己的出生点」。
##
## 注意 escort_finished 是 "call_remote"：**发送方本地不会执行**它。
## → 房主自己被抓时必须本地投递（否则房主自己永远等不到回执，押送卡死）。
func send_escort_finished(peer_id: int) -> void:
	var mp := multiplayer
	if mp == null:
		return
	if mp.get_unique_id() == HOST_PEER_ID:
		# 房主自己被抓 → 本地投递（call_remote 不会在本地执行）。
		escort_finished(peer_id)
		return
	if not mp.get_peers().has(HOST_PEER_ID):
		# 房主不在（房主掉线即本局结束，不重试）。
		return
	escort_finished.rpc_id(HOST_PEER_ID, peer_id)
