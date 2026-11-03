class_name ENetTransport
extends Transport

## ENet 传输实现。开发期用它在同一台机器上开两个进程模拟多人。
##
## 信号语义（跨实现一致，Task 7 的 Session 按这个理解）：
##   host 侧：客户端连进来 → peer_connected(客户端 id)
##             客户端断开     → peer_disconnected(客户端 id)
##   client 侧：连上服务器   → peer_connected(1)（服务器 id）+ server_connected()
##   连接失败 / 已连接后断开 → connection_failed()
##
## peer_connected / peer_disconnected 由底层 MultiplayerPeer 的原生信号驱动
## （见 transport.gd 的说明）；server_connected / connection_failed 由本类
## 依据连接状态发出，并用 _reported_connected / _reported_failure 去重。

var _enet: ENetMultiplayerPeer = null
var _reported_connected := false
var _reported_failure := false


func host(port: int, max_clients: int) -> Error:
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_server(port, max_clients)
	if err != OK:
		# 端口被占等失败：create_server 失败后这个 peer 并没有激活，
		# 不能 close（close 对未激活的 peer 会触发引擎 ERR_FAIL_COND），
		# 直接丢弃即可。
		connection_failed.emit()
		return err
	_enet = enet
	_set_peer(_enet)
	return OK


func join(address: String, port: int) -> Error:
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_client(address, port)
	if err != OK:
		connection_failed.emit()
		return err
	_enet = enet
	_set_peer(_enet)
	return OK


## 手动驱动底层 peer（未挂载到 MultiplayerAPI 时由调用方每帧调用）。
## 已挂载时直接返回：由引擎每帧 poll 同一个 peer，不能 poll 两次。
func poll() -> void:
	if _enet == null or is_attached():
		return
	# 已经断开（连接失败或被 close 掉）的 peer 不能再 poll：
	# 引擎会对未激活的 peer 打 "The multiplayer instance isn't currently active."。
	if _enet.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		_report_disconnected()
		return
	_enet.poll()
	_update_connection_state()


## 依据连接状态发出 server_connected / connection_failed（各自只发一次）。
func _update_connection_state() -> void:
	var state := _enet.get_connection_status()
	if state == MultiplayerPeer.CONNECTION_CONNECTED:
		_reported_failure = false
		# server_connected 是 client 专用信号：host 端不是「连上了服务器」。
		if not _reported_connected and not is_host():
			_reported_connected = true
			server_connected.emit()
	elif state == MultiplayerPeer.CONNECTION_DISCONNECTED:
		_report_disconnected()


## 断开（连接失败 / 已连接后断开）：发 connection_failed()，并清掉已知 peer 集合。
func _report_disconnected() -> void:
	_clear_known_peers()
	if _reported_failure:
		return
	_reported_failure = true
	connection_failed.emit()
