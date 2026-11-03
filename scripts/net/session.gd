extends Node

## 大厅 / 成员 / 回合。**本文件只依赖 Transport 抽象，不引用任何平台专有 API**
## （P2 的平台传输层另立文件，本文件与之无关）。
##
## ------------------------------------------------------------------
## 【本文件没有 class_name 的原因】（实测证据见 task-7-report.md）
## ------------------------------------------------------------------
## 任务书要求 `class_name Session`，全局约束又要求把 Session 注册成**同名 autoload**
## （project.godot 的 [autoload] 段：Session="*res://scripts/net/session.gd"）。
## Godot 4.7.2 里这两件事**互斥**：同名时脚本报
##     Parse Error: Class "Session" hides an autoload singleton.
## 紧接着 autoload 创建失败：
##     ERROR: Failed to create an autoload, script 'res://session.gd' is not compiling.
## （探针：.superpowers/sdd/.../_tmp_task7_review/probe_autoload*）
## → 结论：**不写 class_name**。
##   * 项目里的类型仍然写作 `Session` —— autoload 名可以直接当类型标注用（已实测）；
##   * 需要 new() 的地方（headless 测试）用 `preload("res://scripts/net/session.gd")`；
##   * 另注：autoload 标识符**不能当表达式用**（`Session.new()` 编译期报
##     "Identifier not found: Session"），因为 --script 模式下脚本先于 autoload 创建被编译。
##
## ------------------------------------------------------------------
## 【名单语义：房主为权威】（Task 6 实测结论，Task 7 必须遵守）
## ------------------------------------------------------------------
## ENet server-relay 下，**客户端侧的 Transport.peer_list() 只含服务器（id 1）**，
## 其它玩家（relay peer）只在 MultiplayerAPI 层可见。Task 6 三节点实测：
##   server 原生 id = [c1, c2]，client 原生 id = [1]。
## → 客户端若用本地 peer_list() 算人数，2 人局恰好对、**3 人局必错**。
## → 所以名单一律以房主为权威：
##   * 房主：自己的 id + transport.peer_list()（房主侧 peer_list() 是完整的）；
##   * 客户端：以**收到的**名单为准，不从本地 peer_list() 算；
##   * 名单变化时房主**广播**给所有人。
##
## ★ **roster_changed 的载荷语义**：从「其他 peer」变成「**全员 peer（含房主自己）**」。
##   信号名与参数类型（roster_changed(peers: Array[int])）未变，只是载荷口径变了。
##
## ------------------------------------------------------------------
## 【清单定向发给本人】
## ------------------------------------------------------------------
## 房主生成清单后**按 peer id 定向发送**：每个客户端只拿到自己那一份。
## 若广播整副牌，客户端就能看见别人的清单 —— 不该有的信息泄漏。
## → 房主侧维护「peer id → 该玩家清单」映射表（_deals_by_peer），
##   发送时按 peer id 取对应那一份。
##
## ------------------------------------------------------------------
## 【线格式：清单必须是纯数据】（修复轮 1 的 C1）
## ------------------------------------------------------------------
## **不能**把 Mischief 对象直接当 RPC 参数发 —— Godot 的 RPC 只序列化「纯数据」，
## Object 会被编码成对象 id，跨进程收到的是 **EncodedObjectAsID 占位符**
## （对象的所有字段都读不出来：id/title/category/target_tag 全是空值）。
## 实测证据见 task-7-report.md 第 2 节。
## → 线格式固定为**一张牌 = 一个基础类型字典**，字段清单固定（下游不许各自发明）：
##     {"id": String, "title": String, "category": String, "target_tag": String,
##      "needs_partner": bool, "duration": float, "points": int}
##   （StringName 在线上**一律**转成 String）
## → 客户端 `_apply_deal()` 收到后**本地重建 Mischief 对象**，
##   所以 `deal()` 在**两端**都返回 Mischief 对象的数组（Task 10 / 11 不必知道线格式）。
##
## ------------------------------------------------------------------
## 【广播时机：不能在原生 peer 回调里同步发 RPC】（修复轮 1 的 C2）
## ------------------------------------------------------------------
## 原生 peer 信号（peer_connected）**早于** MultiplayerAPI 的名单刷新，
## 在这个回调里同步 `rpc_id()` 会被引擎拒收：
##     ERROR: Attempt to call RPC with unknown peer ID: <id>
## → 名单的重算与广播统一放到 `_process()` 里做（至少晚一帧），
##   并且 `_send_to()` 会检查目标是否已在 MultiplayerAPI 的名单里，
##   没在就**推迟到下一帧重发**（而不是丢掉）。
##
## ------------------------------------------------------------------
## 【客户端「掉线」的真实原因：房主进程退出】（修复轮 1 实测）
## ------------------------------------------------------------------
## 双进程实测里客户端常常在连上后 ~9 秒掉线。**原因不是 ENet 的空闲超时**：
## 原始 ENet 探针（.superpowers/.../_tmp_task7_review/probe_raw_link.gd）实测
## 完全静默 13.7 秒也不掉线；真正让连接断掉的是**房主子进程先退出** ——
## 房主进程一退出，它的 UDP 端口就消失，客户端下一次收发收到 ICMP 端口不可达
## → 套接字被重置 → ENet 判定连接断开。
## → 写双进程测试时**房主必须比客户端活得久**（见 tools/session_link_child.gd）。
## → 也因此**不需要**「定期重播名单」来保活（那是对现象的错误归因）。
##
## ------------------------------------------------------------------
## 【连接超时兜底只对客户端生效】（修复轮 1 的 C3）
## ------------------------------------------------------------------
## server_connected 是**客户端专用**信号（transport.gd 明确写了房主不发），
## 所以房主建房成功即视为链路已建立，**不启动**连接超时计时器 ——
## 否则房主会在 8 秒后把自己的房间拆掉。
##
## ------------------------------------------------------------------
## 【peer id 会变】
## ------------------------------------------------------------------
## Godot 4 的 ENet 客户端 peer id 是**随机 32 位数**（Task 6 实测 2131996968 等），
## 服务器恒为 1；**重连会换一个新的 peer id**。
## → 用 peer id 做键只保证**单局内**成立。P1 不做 host migration、不做跨局身份保持
##   （房间掉线不做迁移：房主掉线即本局结束）。
##
## ------------------------------------------------------------------
## 【一切判定在房主执行】
## ------------------------------------------------------------------
## start_round() / end_round() 只有房主能真正执行；客户端调用是 no-op。
## 客户端只接收房主发来的名单与「自己那一份清单」。

signal roster_changed(peers: Array[int])
signal round_started(deal: Array)
signal round_ended(summary: Dictionary)

const DEFAULT_PORT := 27015
const ALL_MISCHIEFS := "res://data/mischief.json"
const MAX_CLIENTS := 6

## 连接超时兜底（秒）。
## ENet 的 connect timeout 在 GDScript 侧**不可配置**，Task 6 实测「连不上服务器」
## 要 ~31.5 秒（4567 帧）才发 connection_failed —— 远超一次等待的预算，
## 所以 Session 自己带一个 Timer 兜底：超时后主动 close peer 并回到大厅态。
const CONNECT_TIMEOUT_SEC := 8.0

## 出站台账上限（防止无限增长）。
const OUTBOX_LIMIT := 128

## 推迟发送的最大重试次数（帧）。目标 peer 迟迟不进 MultiplayerAPI 名单时用。
const PENDING_MAX_TRIES := 120

var _transport: Transport = null

## 本机的清单。
##   * 房主：全部手牌（每人一份）—— 房主是裁判，本来就看得见所有人的牌；
##   * 客户端：**只有自己那一份**。
## 两种情况下它都是「若干份清单」的数组，形状一致。
var _deal: Array = []

## 本局可用的目标标签（调用方数组的**副本**，见 set_available_tags）。
var _available_tags: Array[StringName] = []

## 全员名单（房主权威）。房主：自己 + transport.peer_list()；客户端：收到的名单。
var _roster: Array[int] = []

## peer id → 该玩家自己的那一份清单（房主侧）。定向发送用的就是这张表。
var _deals_by_peer: Dictionary = {}

## 出站消息台账：{"peer": int, "method": StringName, "args": Array}
## 既用于自检（断言"发出的数据是对的"），也是排查联机问题的现场记录。
var _outbox: Array = []

## 推迟发送的出站消息：{"peer": int, "method": StringName, "args": Array, "tries": int}
## 目标 peer 还没进 MultiplayerAPI 名单时先存这里，下一帧重发。
var _pending: Array = []

var _timeout_timer: Timer = null


func _ready() -> void:
	_timeout_timer = Timer.new()
	_timeout_timer.one_shot = true
	_timeout_timer.wait_time = CONNECT_TIMEOUT_SEC
	_timeout_timer.timeout.connect(_on_connect_timeout)
	add_child(_timeout_timer)


## 换掉本层用的传输实现（不换 multiplayer 绑定）。
func set_transport(t: Transport) -> void:
	_transport = t
	if t != null:
		_connect_transport_signals(t)


## 设置本局可用的目标标签。
##
## **不会修改调用方传进来的数组**：GDScript 的数组是引用类型，
## 直接赋值会把调用方的数组一起改掉（任务书参考实现在这里有 bug）。
func set_available_tags(tags: Array[StringName]) -> void:
	_available_tags = _copy_tags(tags)


## 开一个房间。失败（端口被占等）时返回非 OK 的 Error，状态保持自洽。
##
## **不启动连接超时计时器**：房主建房成功即视为链路已建立 ——
## server_connected 是客户端专用信号，房主永远等不到它（否则 8 秒后房主会把自己的房间拆掉）。
func host_game(port: int = DEFAULT_PORT) -> Error:
	_ensure_transport()
	var err := _transport.host(port, MAX_CLIENTS)
	if err != OK:
		# 失败就丢弃传输：Session 回到「什么都没开」的状态，
		# 再点一次「创建房间」能干净地重来（I3）。
		_drop_transport()
		_reset_to_lobby()
		return err
	# 刚开房时名单只有自己；有人进来时由 _process → _sync_roster 广播。
	_refresh_roster()
	return OK


## 加入一个房间。失败（地址非法等）时返回非 OK 的 Error，状态保持自洽。
##
## 客户端的名单**不从本地 peer_list() 算**，等房主广播。
## **连接超时兜底只对客户端生效**：连不上时 8 秒后主动放弃并回到大厅态。
func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	_ensure_transport()
	var err := _transport.join(address, port)
	if err != OK:
		_drop_transport()
		_reset_to_lobby()
		return err
	_start_connect_timeout()
	return OK


## 把传输挂到 SceneTree 的 MultiplayerAPI 上。
##
## **调用顺序**：先 host/join 成功，再调本方法 ——
## attach_to() 在 _peer == null 时是**静默返回**的空操作（Task 6 实测）。
## 但**重试不需要重新调**：join 成功会自动把 mp 换绑到新 peer（Task 6 契约）。
func apply_to_multiplayer() -> void:
	if _transport != null:
		_transport.attach_to(multiplayer)


func _process(_delta: float) -> void:
	if _transport == null:
		return
	# 已挂到 multiplayer 的 peer 由引擎每帧 poll，这里不重复驱动
	if not _transport.is_attached():
		_transport.poll()
	# 推迟的出站消息重发（目标 peer 上一帧还没进 MultiplayerAPI 的名单）
	_flush_pending()
	# 房主：名单变了就重算 + 广播。
	# **刻意放在这里而不是原生 peer 回调里** —— 原生 peer 信号早于 MultiplayerAPI
	# 的名单刷新，在回调里同步 rpc_id() 会被引擎拒收（C2）。
	if is_host():
		_sync_roster()


## 本机是不是房主（房主权威：一切联机判定都在房主执行）。
##
## **peer 已经断开（失效）时不再问它 peer id**：ENetMultiplayerPeer.get_unique_id()
## 在 peer 被关闭之后会打引擎 ERROR（"The multiplayer instance isn't currently
## active."），每帧问一次会刷一屏错误（修复轮 1 双进程实测：掉线后 213 条）。
func is_host() -> bool:
	if _transport == null:
		return false
	var p := _transport.get_peer()
	if p == null:
		return false
	if p.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return false
	return _transport.is_host()


## 大厅里的人数（房主权威名单的长度）。
func peer_count() -> int:
	return _roster.size()


## 全员名单（含房主自己）。房主侧是本机算出来的，客户端侧是收到的。
func peers() -> Array[int]:
	return _roster.duplicate()


## 本机的清单。房主 = 全部手牌；客户端 = 只有自己那一份。
## 返回**副本**（与 peers() 的语义一致）：调用方改不动内部状态。
func deal() -> Array:
	return _copy_deal(_deal)


## 房主侧查某个 peer 自己的那一份清单（peer id → 清单 映射表）。
## 定向发送用的就是这张表；它只在**单局内**有效（peer id 重连会变）。
func deal_for_peer(peer_id: int) -> Array:
	var hand: Variant = _deals_by_peer.get(peer_id, null)
	if hand == null:
		return []
	return hand


## ------------------------------------------------------------------
## 回合
## ------------------------------------------------------------------

## 仅房主可调。生成每个人的捣蛋清单，并**按 peer id 定向**发给本人。
## 客户端调用是 **no-op**（不会产生新的回合）。
func start_round() -> void:
	if not is_host():
		return
	var all := Mischief.load_all(ALL_MISCHIEFS)
	var tags := _resolved_tags(all)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var roster := _effective_roster()
	var hands := MischiefDeck.generate(all, roster.size(), rng, tags)
	_deals_by_peer.clear()
	for i in roster.size():
		var hand: Array = []
		if i < hands.size():
			hand = hands[i]
		_deals_by_peer[int(roster[i])] = hand
	_deal = hands
	round_started.emit(_copy_deal(_deal))
	# 定向发送：每人只拿自己那一份（线上是**纯数据字典**，见文件头「线格式」）
	for i in roster.size():
		var pid := int(roster[i])
		if pid == _own_peer_id():
			continue
		var hand: Array = _deals_by_peer.get(pid, [])
		_send_to(pid, &"_rpc_apply_deal", [_hand_to_wire(hand)])


## 房主随时可以「收工」，**不惩罚任何人**（摘要原样透传，不追加任何额外字段）。
func end_round(summary: Dictionary = {}) -> void:
	if not is_host():
		return
	_deal = []
	_deals_by_peer.clear()
	round_ended.emit(summary.duplicate())
	for pid in _client_peer_ids():
		_send_to(pid, &"_rpc_apply_round_ended", [summary])


## ------------------------------------------------------------------
## 名单（房主权威）
## ------------------------------------------------------------------

## 【接收入口】收到房主广播的名单 → 应用。
## 真实 RPC 的目标方法 _rpc_apply_roster 直接调它；
## headless 单进程测试也直调它（两个 peer 不能挂在同一个 MultiplayerAPI 上，
## 真实 RPC 链在单进程里跑不通）。
func _apply_roster(roster: Array) -> void:
	var next: Array[int] = []
	for p in roster:
		next.append(int(p))
	_roster = next
	roster_changed.emit(_roster.duplicate())


## 【接收入口】收到「自己的那一份清单」→ 应用（客户端）。
##
## 线上的载荷是**纯数据字典**（见文件头「线格式」），这里**本地重建 Mischief 对象**，
## 所以 deal() 在两端都返回 Mischief 数组。
func _apply_deal(my_hand: Array) -> void:
	_deal = [_hand_from_wire(my_hand)]
	round_started.emit(_copy_deal(_deal))


## 【接收入口】收到收工通知 → 应用（客户端）。
func _apply_round_ended(summary: Dictionary) -> void:
	_deal = []
	round_ended.emit(summary.duplicate())


## 房主侧重算名单（本地应用）。
func _refresh_roster() -> void:
	if not is_host():
		return
	_apply_roster(_host_roster())


## 房主：名单变了就重算 + 广播（**每帧**在 _process 里调）。
##
## **刻意不在原生 peer 回调里做**：原生 peer 信号早于 MultiplayerAPI 的名单刷新，
## 在回调里同步 rpc_id() 会被引擎拒收（"Attempt to call RPC with unknown peer ID"，C2）。
func _sync_roster() -> void:
	if not is_host():
		return
	var roster := _host_roster()
	if roster == _roster:
		return
	_apply_roster(roster)
	_broadcast_roster(roster)


## 房主看到的全员名单：自己 + transport.peer_list()。
## （房主侧的 peer_list() 是完整的；客户端侧不是，见文件头。）
func _host_roster() -> Array[int]:
	var out: Array[int] = []
	if _transport == null:
		return out
	var own := _transport.get_peer_id()
	out.append(own)
	for id in _transport.peer_list():
		if id != own:
			out.append(int(id))
	return out


## 本轮生效的名单：房主自己算，客户端用收到的。
func _effective_roster() -> Array[int]:
	if is_host():
		return _host_roster()
	return _roster


## 除自己以外的 peer id（发送对象）。
func _client_peer_ids() -> Array[int]:
	var out: Array[int] = []
	var own := _own_peer_id()
	for id in _effective_roster():
		if id != own:
			out.append(int(id))
	return out


func _broadcast_roster(roster: Array) -> void:
	for id in roster:
		if int(id) == _own_peer_id():
			continue
		_send_to(int(id), &"_rpc_apply_roster", [roster])


## ------------------------------------------------------------------
## 出站
## ------------------------------------------------------------------

## 发一条消息给某个 peer（**只有房主发**）。
##
## 这里刻意做成一个独立方法：headless 单进程里两个 peer 不能挂在同一个
## MultiplayerAPI 上，真实 RPC 链跑不通 —— 把「发」这一步单独拎出来，
## 测试才能断言"发出的数据是对的"（出站台账 _outbox）。
func _send_to(peer_id: int, method: StringName, args: Array) -> void:
	_record_out(peer_id, method, args)
	if not _can_rpc(peer_id):
		return
	if not _peer_in_api(peer_id):
		# 目标还没进 MultiplayerAPI 的名单（原生 peer 信号比 API 名单早）→ 下一帧再发
		_pending.append({"peer": peer_id, "method": method, "args": args, "tries": 0})
		return
	_do_rpc(peer_id, method, args)


## 目标 peer 是否已经在 MultiplayerAPI 的名单里。
func _peer_in_api(peer_id: int) -> bool:
	var mp := multiplayer
	if mp == null:
		return false
	return mp.get_peers().has(peer_id)


## 重发上一帧没能发出去的消息（目标 peer 那时还没进 API 名单）。
func _flush_pending() -> void:
	if _pending.is_empty():
		return
	var still: Array = []
	for item in _pending:
		var pid := int(item["peer"])
		if _peer_in_api(pid):
			_do_rpc(pid, item["method"], item["args"])
		elif int(item["tries"]) < PENDING_MAX_TRIES:
			item["tries"] = int(item["tries"]) + 1
			still.append(item)
	_pending = still


## 真正发出 RPC。
func _do_rpc(peer_id: int, method: StringName, args: Array) -> void:
	match method:
		&"_rpc_apply_roster":
			rpc_id(peer_id, "_rpc_apply_roster", args[0])
		&"_rpc_apply_deal":
			rpc_id(peer_id, "_rpc_apply_deal", args[0])
		&"_rpc_apply_round_ended":
			rpc_id(peer_id, "_rpc_apply_round_ended", args[0])
		_:
			push_error("[Session] 未知的出站消息：" + String(method))


## 能不能真的发这条 RPC？
##
## 三个条件缺一不可：
##   1. mp 上挂了 peer；
##   2. mp 上挂的**就是本层这个 peer**（生产里由 apply_to_multiplayer() 挂上）——
##      否则说明还没有真实链路，发出去只会被引擎拒绝
##      （"Attempt to call RPC with unknown peer ID"）；
##   3. 目标不是自己。
## → headless 单进程测试里两个 Session 都没有 apply_to_multiplayer()，
##   条件 2 不成立 → 不会发出任何 RPC（测试改用接收入口直调，见文件头）。
func _can_rpc(peer_id: int) -> bool:
	var mp := multiplayer
	if mp == null:
		return false
	var peer := mp.multiplayer_peer
	if peer == null:
		return false
	# peer 已经断开（失效）时不要再问它 peer id（会打引擎 ERROR，见 is_host 的说明）。
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return false
	if _transport == null or _transport.get_peer() != peer:
		return false
	return peer.get_unique_id() != peer_id


func _record_out(peer_id: int, method: StringName, args: Array) -> void:
	_outbox.append({"peer": peer_id, "method": method, "args": args})
	while _outbox.size() > OUTBOX_LIMIT:
		_outbox.remove_at(0)


## ------------------------------------------------------------------
## RPC 目标方法（房主 → 客户端）
## ------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _rpc_apply_roster(roster: Array) -> void:
	_apply_roster(roster)


@rpc("authority", "call_remote", "reliable")
func _rpc_apply_deal(my_hand: Array) -> void:
	_apply_deal(my_hand)


@rpc("authority", "call_remote", "reliable")
func _rpc_apply_round_ended(summary: Dictionary) -> void:
	_apply_round_ended(summary)


## ------------------------------------------------------------------
## 传输层信号
## ------------------------------------------------------------------

func _ensure_transport() -> void:
	if _transport != null:
		return
	_transport = ENetTransport.new()
	_connect_transport_signals(_transport)


func _connect_transport_signals(t: Transport) -> void:
	if not t.peer_connected.is_connected(_on_transport_peer_connected):
		t.peer_connected.connect(_on_transport_peer_connected)
	if not t.peer_disconnected.is_connected(_on_transport_peer_disconnected):
		t.peer_disconnected.connect(_on_transport_peer_disconnected)
	if not t.server_connected.is_connected(_on_transport_server_connected):
		t.server_connected.connect(_on_transport_server_connected)
	if not t.connection_failed.is_connected(_on_transport_connection_failed):
		t.connection_failed.connect(_on_transport_connection_failed)


func _on_transport_peer_connected(_id: int) -> void:
	# 什么都不做：名单的重算与广播统一由 _process → _sync_roster 负责
	# （原生 peer 信号早于 MultiplayerAPI 的名单刷新，在回调里发 RPC 会被拒收 —— C2）。
	pass


func _on_transport_peer_disconnected(_id: int) -> void:
	# 同上：交给 _process → _sync_roster。
	pass


func _on_transport_server_connected() -> void:
	_stop_connect_timeout()


func _on_transport_connection_failed() -> void:
	# 房主掉线 = 本局结束（不做 host migration）。
	_reset_to_lobby()


## ------------------------------------------------------------------
## 超时兜底 / 状态复位
## ------------------------------------------------------------------

func _start_connect_timeout() -> void:
	if _timeout_timer != null:
		_timeout_timer.start(CONNECT_TIMEOUT_SEC)


func _stop_connect_timeout() -> void:
	if _timeout_timer != null:
		_timeout_timer.stop()


func _on_connect_timeout() -> void:
	# ENet 的 connect timeout 不可配置，"连不上服务器"要 ~31.5 秒才报
	# connection_failed —— 这里自己兜底：主动 close peer，回到大厅态。
	push_warning("[Session] 连接超时，已放弃本次连接")
	_drop_transport()
	_reset_to_lobby()


## 关闭并丢弃当前传输（超时兜底 / 开房失败时用）。
## Transport 层把 peer 生命周期收在它自己那一层（Task 6 契约），本文件不改它；
## 所以这里：先让 mp 松手，再 close 底层 peer，最后把 _transport 置空 ——
## Session 侧状态立刻自洽（is_host() == false / peer_count() == 0 / 清单为空）。
func _drop_transport() -> void:
	if _transport != null:
		var p := _transport.get_peer()
		if p != null:
			# attached 模式：**必须先让 mp 松手**，再关 peer ——
			# 否则 mp 还在 poll 一个已被关掉的 peer，引擎会打 ERROR。
			if _transport.is_attached():
				var mp := multiplayer
				if mp != null and mp.multiplayer_peer == p:
					mp.multiplayer_peer = null
			if p.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
				p.close()
	_transport = null


## 回到大厅态：清空名单与清单，并让界面能刷新。
func _reset_to_lobby() -> void:
	_stop_connect_timeout()
	_roster.clear()
	_deal = []
	_deals_by_peer.clear()
	roster_changed.emit(_roster.duplicate())


## ------------------------------------------------------------------
## 工具
## ------------------------------------------------------------------

## 本局生效的标签：调用方给的就用调用方给的（副本），没给就从数据里取全部标签。
## **任何情况下都不改调用方的数组。**
func _resolved_tags(all: Array[Mischief]) -> Array[StringName]:
	if not _available_tags.is_empty():
		return _copy_tags(_available_tags)
	var out: Array[StringName] = []
	for m in all:
		out.append(m.target_tag)
	return out


func _copy_tags(tags: Array[StringName]) -> Array[StringName]:
	var out: Array[StringName] = []
	for t in tags:
		out.append(t)
	return out


## ------------------------------------------------------------------
## 线格式（纯数据 ⇄ Mischief 对象）
## ------------------------------------------------------------------

## 一份清单（Mischief 数组）→ 线格式（**纯数据字典**数组）。
func _hand_to_wire(hand: Array) -> Array:
	var out: Array = []
	for m in hand:
		out.append(_mischief_to_wire(m))
	return out


## 线格式 → 一份清单（**本地重建** Mischief 对象）。
func _hand_from_wire(wire_hand: Array) -> Array:
	var out: Array = []
	for d in wire_hand:
		if d is Dictionary:
			out.append(_mischief_from_wire(d))
		elif d is Mischief:
			out.append(d)
	return out


## 一张牌 → 线格式字典（7 个固定字段；StringName 一律转 String）。
func _mischief_to_wire(m: Mischief) -> Dictionary:
	return {
		"id": String(m.id),
		"title": String(m.title),
		"category": String(m.category),
		"target_tag": String(m.target_tag),
		"needs_partner": bool(m.needs_partner),
		"duration": float(m.duration),
		"points": int(m.points),
	}


## 线格式字典 → 本地重建的 Mischief 对象。
func _mischief_from_wire(d: Dictionary) -> Mischief:
	var m := Mischief.new()
	m.id = StringName(str(d.get("id", "")))
	m.title = str(d.get("title", ""))
	m.category = StringName(str(d.get("category", "")))
	m.target_tag = StringName(str(d.get("target_tag", "")))
	m.needs_partner = bool(d.get("needs_partner", false))
	m.duration = float(d.get("duration", 0.0))
	m.points = int(d.get("points", 0))
	return m


## 清单的深一层拷贝（外层 + 每份手牌）。
func _copy_deal(deal: Array) -> Array:
	var out: Array = []
	for hand in deal:
		out.append((hand as Array).duplicate())
	return out


func _own_peer_id() -> int:
	return 1 if _transport == null else _transport.get_peer_id()
