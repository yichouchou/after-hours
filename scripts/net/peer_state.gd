class_name PeerState
extends RefCounted

## 「这台机器在联机里是谁」与「mp 上有没有 peer」的唯一判定入口。
##
## ------------------------------------------------------------------
## 【为什么必须有这一层】
## ------------------------------------------------------------------
## 场景层裸调 multiplayer.get_unique_id() / is_server() /
## is_multiplayer_authority() 时，**一旦 mp 上没有 peer**，引擎就会每帧打一条
## ERROR（scene_multiplayer.cpp:531
##   "No multiplayer peer is assigned. Unable to get unique ID."）
## → 屏幕全是红字；而且 get_unique_id() 返回 0
##   → is_multiplayer_authority() 恒为 false → **输入被整个忽略（角色卡住）**
##   → is_server() 恒为 false → **守卫 AI 整场停摆**。
## （2026-11-04 用户报障；headless 探针 100% 复现，556 条 ERROR / 帧）
##
## ------------------------------------------------------------------
## 【口径：没有 peer = 本机单机当房主】
## ------------------------------------------------------------------
## Godot 的**默认** multiplayer peer 就是 OfflineMultiplayerPeer：
##   unique_id == 1、is_server() == true。
## → 所以「没有 peer」在**引擎自己的口径**里就是「本机即房主（peer id 1）」，
##   **不是**「本机什么都不是」。
## → 本文件按这个口径统一判定，并提供 restore_offline() 把 mp 恢复到该状态
##   （mp 上永远不留 null peer）。
##
## ------------------------------------------------------------------
## 【纯静态函数】
## ------------------------------------------------------------------
## 不碰场景树、不读节点状态 → 可以直接单测（tools/test_peer_null.gd）。

## 房主的 peer id（ENet server-relay：服务器恒为 1）。
const HOST_PEER_ID := 1


## mp 上有没有挂着 peer。
static func has_peer(mp: MultiplayerAPI) -> bool:
	return mp != null and mp.multiplayer_peer != null


## 本机的 peer id。
##
## ★ 没有 peer 时返回 1（引擎默认口径：本机即房主）。
## ★ 绝不裸调 mp.get_unique_id() —— peer 为 null 时它会打引擎 ERROR。
static func local_peer_id(mp: MultiplayerAPI) -> int:
	if not has_peer(mp):
		return HOST_PEER_ID
	return mp.get_unique_id()


## 本机是不是房主（守卫 AI 与捣蛋裁决都在房主跑）。
static func is_local_host(mp: MultiplayerAPI) -> bool:
	return local_peer_id(mp) == HOST_PEER_ID


## 这个节点是不是**本机拥有**的（移动由本机算）。
##
## ★ 有 peer → 用引擎的 is_multiplayer_authority()；
## ★ 没有 peer → 按上面的口径：权威 == 1 的节点归本机（房主的那个化身）。
static func owns_node(node: Node) -> bool:
	if node == null or not node.is_inside_tree():
		return false
	var mp := node.get_multiplayer()
	if not has_peer(mp):
		return node.get_multiplayer_authority() == HOST_PEER_ID
	return node.is_multiplayer_authority()


## 把 mp 恢复成「单机」状态：挂一个 OfflineMultiplayerPeer。
##
## ★ 为什么需要这一步：mp.multiplayer_peer == null 时，引擎每帧打一条 ERROR，
##   get_unique_id() 返回 0 → is_multiplayer_authority() 恒为 false
##   → **输入被整个忽略、角色卡住**（2026-11-04 实测）。
## ★ OfflineMultiplayerPeer 正是引擎自己的默认值（unique_id 1 / is_server true）
##   → 语义上就是「本机单机当房主」，与引擎口径完全一致。
static func restore_offline(mp: MultiplayerAPI) -> void:
	if mp == null:
		return
	if mp.multiplayer_peer == null:
		mp.multiplayer_peer = OfflineMultiplayerPeer.new()
