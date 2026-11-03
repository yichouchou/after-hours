class_name Transport
extends RefCounted

## 联网传输层抽象。Gameplay 层只认这个接口，不认具体实现。
##
## P1 只有 ENetTransport；P2 增加 SteamTransport（内部用 SteamMultiplayerPeer）。
##
## 已知 peer 集合怎么来的（Godot 4.7.2 实测结论）：
##   MultiplayerPeer **没有** get_peers()（get_peers() 是 MultiplayerAPI 上的方法，
##   brief 参考实现里的 `_peer.get_peers()` 在 4.7.2 会直接抛
##   "Nonexistent function 'get_peers'"）。所以 peer_list() 由本类自己维护
##   「已知 peer 集合」：订阅底层 MultiplayerPeer 的原生
##   peer_connected / peer_disconnected 信号 → 更新集合 → 转发成本类的同名信号。
##   这两个信号是 MultiplayerPeer 的基类 API，ENet 与 Steam 都有，
##   因此这一层对 P1 / P2 两种实现通用，Session 层不需要改接入逻辑。

signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal server_connected()
signal connection_failed()

var _peer: MultiplayerPeer = null
var _attached := false
# 已知 peer id 集合：int -> true
var _known_peers: Dictionary = {}


func host(_port: int, _max_clients: int) -> Error:
	push_error("Transport.host 未实现")
	return ERR_UNAVAILABLE


func join(_address: String, _port: int) -> Error:
	push_error("Transport.join 未实现")
	return ERR_UNAVAILABLE


func poll() -> void:
	pass


## 挂到给定的 MultiplayerAPI 上。挂上之后由引擎每帧自动 poll，
## 本类不再重复 poll（避免同一 peer 被 poll 两次）。
##
## 注意：原生信号是绑在 _peer 对象上的，与「谁在 poll」无关，
## 所以挂载之后 peer_connected / peer_disconnected 照常发出。
func attach_to(mp: MultiplayerAPI) -> void:
	if _peer == null:
		return
	mp.multiplayer_peer = _peer
	_attached = true


func is_attached() -> bool:
	return _attached


func get_peer() -> MultiplayerPeer:
	return _peer


func get_peer_id() -> int:
	return 1 if _peer == null else _peer.get_unique_id()


func is_host() -> bool:
	return _peer != null and _peer.get_unique_id() == 1


## 当前已知的对端 peer id（升序）。未连接时是空数组。
func peer_list() -> Array[int]:
	var out: Array[int] = []
	for peer_id in _known_peers.keys():
		out.append(int(peer_id))
	out.sort()
	return out


## 绑定底层 peer：保存引用 + 订阅原生 peer 信号。
## 由具体实现（host / join 成功后）调用。
func _set_peer(p: MultiplayerPeer) -> void:
	_peer = p
	_known_peers.clear()
	if _peer == null:
		return
	if not _peer.peer_connected.is_connected(_on_peer_connected):
		_peer.peer_connected.connect(_on_peer_connected)
	if not _peer.peer_disconnected.is_connected(_on_peer_disconnected):
		_peer.peer_disconnected.connect(_on_peer_disconnected)


## 底层 peer 报告有新对端接入：更新已知集合并转发。
func _on_peer_connected(id: int) -> void:
	_known_peers[id] = true
	peer_connected.emit(id)


## 底层 peer 报告对端离开：更新已知集合并转发。
func _on_peer_disconnected(id: int) -> void:
	_known_peers.erase(id)
	peer_disconnected.emit(id)


## 断开后已知 peer 集合不再有意义（连接已经没了）。
func _clear_known_peers() -> void:
	_known_peers.clear()
