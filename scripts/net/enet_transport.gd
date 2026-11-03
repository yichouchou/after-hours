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
## （见 transport.gd 的说明）；server_connected / connection_failed 由基类按
## 连接状态发出（attached 模式下由 MultiplayerAPI 的信号驱动），
## 并用一次性闩锁去重——闩锁在每次 host() / join() 尝试前复位，
## 所以同一个对象重试或重连时信号不会被静默吞掉。
##
## 已知 peer 集合的语义收窄（client 侧只含服务器）见 transport.gd 的文件头。
##
## 连接失败信号的时延：ENet 的 connect timeout 在 GDScript 侧不可配置，
## 实测约 31.5 秒之后连接状态才转成 DISCONNECTED、才会发 connection_failed()。
## 上层必须自带超时兜底并在超时后主动 close peer。

var _enet: ENetMultiplayerPeer = null


func host(port: int, max_clients: int) -> Error:
	# 新的尝试：复位闩锁（失败也要能被报出来），并关掉上一个 peer。
	_reset_connection_latches()
	_close_previous_peer()
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_server(port, max_clients)
	if err != OK:
		# 端口被占等失败：create_server 失败后这个 peer 并没有激活，
		# 不能 close（close 对未激活的 peer 会触发引擎 ERR_FAIL_COND），
		# 直接丢弃即可。
		_emit_connection_failed()
		return err
	_enet = enet
	_set_peer(_enet)
	return OK


func join(address: String, port: int) -> Error:
	_reset_connection_latches()
	_close_previous_peer()
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_client(address, port)
	if err != OK:
		_emit_connection_failed()
		return err
	_enet = enet
	_set_peer(_enet)
	return OK


## 手动驱动底层 peer（未挂载到 MultiplayerAPI 时由调用方每帧调用）。
##
## 已挂载时**绝不**再次 poll 底层 peer（由引擎 / MultiplayerAPI 负责），
## 只读连接状态（get_connection_status() 是纯查询），因此 attached 模式下
## server_connected / connection_failed 依然由基类照常发出。
func poll() -> void:
	if _enet == null:
		return
	if not is_attached():
		# 已经断开（连接失败或被 close 掉）的 peer 不能再 poll：
		# 引擎会对未激活的 peer 打 "The multiplayer instance isn't currently active."。
		if _enet.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
			_report_disconnected()
			return
		_enet.poll()
	# 依据连接状态发信号（基类实现，只读状态，不 poll peer）。
	super.poll()


## 关掉上一个 peer（如果还活着），避免端口泄漏 / 旧连接残留。
##
## 已经被 close 掉（或已经断开）的 peer 再 close 会触发引擎 ERR_FAIL_COND，
## 所以用连接状态判断：DISCONNECTED 一律不再 close。
func _close_previous_peer() -> void:
	if _enet == null:
		return
	if _enet.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		_enet.close()
