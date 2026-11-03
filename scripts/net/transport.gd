class_name Transport
extends RefCounted

## 联网传输层抽象。Gameplay 层只认这个接口，不认具体实现。
##
## P1 只有 ENetTransport；P2 增加 SteamTransport（内部用 SteamMultiplayerPeer）。
##
## ------------------------------------------------------------------
## 【peer_list() 的语义收窄（重要，Task 7 必读）】
## ------------------------------------------------------------------
## peer_list() 返回的是「底层 MultiplayerPeer 的**原生 peer 信号**报上来的对端」。
## Godot 4.7.2 实测（ENet server-relay，三节点）：
##   * 房主侧：能看到全部客户端（每个客户端接入时报一次 peer_connected）。
##   * 客户端侧：**只能看到服务器（id 1）**。其它玩家（relay peer）只在
##     MultiplayerAPI 层可见（api.get_peers() / api.peer_connected），
##     原生 peer 信号**不发**，所以本层的 peer_list() 收不到。
## 也就是说：**不能用客户端侧的 peer_list() 枚举大厅成员**（永远只有房主一人）。
## 大厅名单请以房主为权威（房主侧名单完整）由房主广播，或从已挂载的
## MultiplayerAPI.get_peers() 取名单。裁决建议见 task-6-report.md 第 2 节。
##
## ------------------------------------------------------------------
## 【连接失败信号的时延（重要，Task 7 必读）】
## ------------------------------------------------------------------
## 「连不上服务器」时，ENet 的 connect timeout 在 GDScript 侧**不可配置**，
## 实测约 31.5 秒（4567 帧）之后连接状态才转成 DISCONNECTED，本层才会发
## connection_failed()。→ 上层必须自带超时兜底，并在超时后主动 close peer。
##
## ------------------------------------------------------------------
## 【attached 模式的信号来源（契约）】
## ------------------------------------------------------------------
## attach_to() 之后由引擎（MultiplayerAPI）每帧 poll 底层 peer，本类的 poll()
## 不再重复 poll（避免同一 peer 被 poll 两次）。但「连上服务器 / 连接失败 /
## 掉线」这三件事**仍然要报给上层**，做法是 attach_to() 里订阅 MultiplayerAPI 的
## 对应信号并转发：
##     connected_to_server → server_connected()
##     connection_failed   → connection_failed()
##     server_disconnected → connection_failed()
## → **上层不依赖、也不需要每帧调用 transport.poll() 才能拿到这些信号**；
##   attach 之后它们照常发。poll() 在已挂载时只读连接状态
##   （get_connection_status() 是纯查询），绝不会再次 poll 底层 peer。

signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal server_connected()
signal connection_failed()

var _peer: MultiplayerPeer = null
var _attached := false
# 已知 peer id 集合：int -> true
var _known_peers: Dictionary = {}
# 「连上服务器 / 连接失败」的一次性闩锁：每次 host()/join() 尝试前复位，
# 保证同一个对象重试 / 重连时信号不会被静默吞掉。
var _reported_connected := false
var _reported_failure := false


func host(_port: int, _max_clients: int) -> Error:
	push_error("Transport.host 未实现")
	return ERR_UNAVAILABLE


func join(_address: String, _port: int) -> Error:
	push_error("Transport.join 未实现")
	return ERR_UNAVAILABLE


## 默认实现：只读连接状态并据此发信号，**不 poll 底层 peer**。
## 具体实现（ENetTransport）在未挂载时会先 poll 底层 peer，再调用本方法。
func poll() -> void:
	if _peer == null:
		return
	var state := _peer.get_connection_status()
	if state == MultiplayerPeer.CONNECTION_CONNECTED:
		_clear_failure_report()
		# server_connected 是 client 专用信号：房主不是「连上了服务器」。
		if not is_host():
			_emit_server_connected()
	elif state == MultiplayerPeer.CONNECTION_DISCONNECTED:
		_report_disconnected()


## 挂到给定的 MultiplayerAPI 上。挂上之后由引擎每帧自动 poll 底层 peer，
## 本类不再重复 poll（避免同一 peer 被 poll 两次）。
##
## 同时订阅 MultiplayerAPI 的连接类信号并转发成本类的信号
## （见文件头「attached 模式的信号来源」）：
## attached 模式下即使上层不调用 poll()，server_connected / connection_failed
## 也照常发出。
func attach_to(mp: MultiplayerAPI) -> void:
	if _peer == null:
		return
	mp.multiplayer_peer = _peer
	_attached = true
	if not mp.connected_to_server.is_connected(_on_mp_connected_to_server):
		mp.connected_to_server.connect(_on_mp_connected_to_server)
	if not mp.connection_failed.is_connected(_on_mp_connection_failed):
		mp.connection_failed.connect(_on_mp_connection_failed)
	if not mp.server_disconnected.is_connected(_on_mp_server_disconnected):
		mp.server_disconnected.connect(_on_mp_server_disconnected)


func is_attached() -> bool:
	return _attached


func get_peer() -> MultiplayerPeer:
	return _peer


func get_peer_id() -> int:
	return 1 if _peer == null else _peer.get_unique_id()


func is_host() -> bool:
	return _peer != null and _peer.get_unique_id() == 1


## 当前已知的对端 peer id（升序）。未连接时是空数组。
##
## 注意语义收窄：**客户端侧只含服务器**，其它玩家（relay peer）不在其中，
## 详见文件头「peer_list() 的语义收窄」。
func peer_list() -> Array[int]:
	var out: Array[int] = []
	for peer_id in _known_peers.keys():
		out.append(int(peer_id))
	out.sort()
	return out


## 绑定底层 peer：保存引用 + 订阅原生 peer 信号。
## 由具体实现（host / join 成功后）调用。
func _set_peer(p: MultiplayerPeer) -> void:
	if _peer != null and _peer != p:
		# 解开旧 peer 的信号绑定：否则 peer → callable → transport → peer
		# 构成引用环，旧 peer 不会被回收。
		_unbind_peer(_peer)
	_peer = p
	_known_peers.clear()
	# 换 peer = 新的连接尝试：复位两个闩锁，
	# 否则重试 / 重连时 server_connected / connection_failed 会被静默吞掉。
	_reset_connection_latches()
	if _peer == null:
		return
	if not _peer.peer_connected.is_connected(_on_peer_connected):
		_peer.peer_connected.connect(_on_peer_connected)
	if not _peer.peer_disconnected.is_connected(_on_peer_disconnected):
		_peer.peer_disconnected.connect(_on_peer_disconnected)


## 解开某个 peer 上的原生信号绑定。
func _unbind_peer(p: MultiplayerPeer) -> void:
	if p == null:
		return
	if p.peer_connected.is_connected(_on_peer_connected):
		p.peer_connected.disconnect(_on_peer_connected)
	if p.peer_disconnected.is_connected(_on_peer_disconnected):
		p.peer_disconnected.disconnect(_on_peer_disconnected)


## 底层 peer 报告有新对端接入：更新已知集合并转发。
func _on_peer_connected(id: int) -> void:
	_known_peers[id] = true
	peer_connected.emit(id)


## 底层 peer 报告对端离开：更新已知集合并转发。
func _on_peer_disconnected(id: int) -> void:
	_known_peers.erase(id)
	peer_disconnected.emit(id)


## MultiplayerAPI 报告「连上服务器了」→ server_connected()。
func _on_mp_connected_to_server() -> void:
	_emit_server_connected()


## MultiplayerAPI 报告「连接失败」→ connection_failed()。
func _on_mp_connection_failed() -> void:
	_emit_connection_failed()


## MultiplayerAPI 报告「和服务器断开了」→ connection_failed()。
func _on_mp_server_disconnected() -> void:
	_emit_connection_failed()


## 发 server_connected()（一次性闩锁）。
func _emit_server_connected() -> void:
	if _reported_connected:
		return
	_reported_connected = true
	server_connected.emit()


## 发 connection_failed()（一次性闩锁）。
func _emit_connection_failed() -> void:
	if _reported_failure:
		return
	_reported_failure = true
	connection_failed.emit()


## 复位两个闩锁：每次 host() / join() 尝试前调用，
## 保证重试 / 重连时信号不会被静默吞掉。
func _reset_connection_latches() -> void:
	_reported_connected = false
	_reported_failure = false


## 连接恢复后清掉「失败已上报」标记。
func _clear_failure_report() -> void:
	_reported_failure = false


## 断开（连接失败 / 已连接后断开）：清掉已知 peer 集合并发 connection_failed()。
func _report_disconnected() -> void:
	_clear_known_peers()
	_emit_connection_failed()


## 断开后已知 peer 集合不再有意义（连接已经没了）。
func _clear_known_peers() -> void:
	_known_peers.clear()
