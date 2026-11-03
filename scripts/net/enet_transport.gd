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
	# 新的尝试：复位闩锁（失败也要能被报出来）。
	_reset_connection_latches()
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_server(port, max_clients)
	if err != OK:
		# 端口被占等失败：create_server 失败后这个 peer 并没有激活，
		# 不能 close（close 对未激活的 peer 会触发引擎 ERR_FAIL_COND），
		# 直接丢弃即可。
		_drop_current_peer()
		_emit_connection_failed()
		return err
	_swap_peer(enet)
	return OK


func join(address: String, port: int) -> Error:
	_reset_connection_latches()
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_client(address, port)
	if err != OK:
		_drop_current_peer()
		_emit_connection_failed()
		return err
	_swap_peer(enet)
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


## 换上新 peer：先让 mp（如果已挂载）指向新 peer，再关掉旧 peer。
##
## 顺序不能反：先关旧 peer 的话，mp 还在 poll 它，会报出一条「旧连接断了」的
## 伪 connection_failed；而且新 peer 没人 poll，连接永远建立不起来。
func _swap_peer(new_peer: ENetMultiplayerPeer) -> void:
	var old := _enet
	_enet = new_peer
	# _set_peer 内部会把已挂载的 mp 换绑到新 peer。
	_set_peer(_enet)
	# 旧 peer 此时已经不在 mp 上了，close 它是安全的（端口 / socket 立即释放）。
	_close_peer(old)


## 失败路径：把本层的 peer 状态清空并自洽。
##
## 失败之后 get_peer() 必须是 null、get_peer_id() 必须是约定的 1、is_host() 必须是 false，
## 而且不能留下一个「已被本层关掉」的旧 peer 让上层拿到（那会让 get_peer_id() 返回 0）。
func _drop_current_peer() -> void:
	var old := _enet
	_enet = null
	_clear_peer_state()
	if is_attached():
		# 已挂 mp：旧 peer 还挂在 mp 上，mp 会继续 poll 它。
		# 这时候**不能** close 它——mp 之后 poll 一个未激活的 peer 会打
		# "The multiplayer instance isn't currently active."。
		# 旧 peer 的信号绑定已在 _clear_peer_state() 里解开了，不会再往上传。
		return
	# 没挂 mp：旧 peer 只有本层引用，直接释放。
	_close_peer(old)


## 关闭一个 peer（如果还活着）。
##
## 已经被 close 掉 / 已经断开的 peer 再 close 会触发引擎 ERR_FAIL_COND，
## 所以用连接状态判断：DISCONNECTED 一律不再 close。
func _close_peer(p: ENetMultiplayerPeer) -> void:
	if p == null:
		return
	if p.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	p.close()
