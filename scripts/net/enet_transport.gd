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
## 连接状态发出（attached 模式下由 MultiplayerAPI 的信号驱动）。
##
## 已知 peer 集合的语义收窄（client 侧只含服务器）见 transport.gd 的文件头。
##
## 连接失败信号的时延：ENet 的 connect timeout 在 GDScript 侧不可配置，
## 实测约 31.5 秒之后连接状态才转成 DISCONNECTED、才会发 connection_failed()。
## 上层必须自带超时兜底并在超时后主动 close peer。
##
## ------------------------------------------------------------------
## 【peer 生命周期契约 —— 与 transport.gd 顶部那一节一一对应】
## ------------------------------------------------------------------
## host() 与 join() 的步骤顺序**完全一致**，只差 create_server / create_client：
##   1. _begin_swap()             进入替换：抑制期间的连接事件
##   2. _detach_multiplayer_peer() mp 解绑（必须在关旧 peer 之前）
##   3. _release_current_peer()   释放旧 peer（先关 → 同端口能立刻重绑）
##   4. create_server / create_client  创建新 peer（失败 → 失败路径）
##   5. _set_peer(new)            换绑：新 peer 成为当前 peer，mp 换绑到新 peer
##   6. _end_swap()                退出替换：解除抑制 + 复位闩锁
##
## 失败路径（第 4 步失败）：
##   - 本层状态清空并自洽（_peer == null / get_peer_id() == 1 / is_host() == false /
##     peer_list() 为空），mp 里也不留残留连接（第 2 步已经解绑）；
##   - 明确发一次 connection_failed()（在 _end_swap() 之后，闩锁保证只发一次）。
##
## 「先关旧 peer 再 create」是 NEW-4 的关键：同一个对象在**同一个端口**上二次
## host() 必须成功（端口在 create_server 之前就释放了）。
## 而「mp 先解绑再关旧 peer」保证 attached 模式下不会产生伪 connection_failed
## （替换期间的事件由 _suppress_peer_events 抑制）。

var _enet: ENetMultiplayerPeer = null


## 开一个服务器。失败（端口被占等）时返回非 OK 的 Error 并发一次 connection_failed()。
func host(port: int, max_clients: int) -> Error:
	# 1. 进入替换：抑制本次替换期间上报上来的任何连接事件
	_begin_swap()
	# 2. mp 解绑（必须在关旧 peer 之前，否则 mp 会 poll 一个被关掉的 peer）
	_detach_multiplayer_peer()
	# 3. 释放旧 peer（先关 → 同端口可以立刻重新绑定）
	_release_current_peer()
	# 4. 创建新 peer
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_server(port, max_clients)
	if err != OK:
		# create_server 失败后这个 peer 并没有激活，不能 close
		# （close 对未激活的 peer 会触发引擎 ERR_FAIL_COND），直接丢弃即可。
		# 失败路径：状态已经自洽（_release_current_peer 已经清过），这里只报一次失败。
		_end_swap()
		_emit_connection_failed()
		return err
	# 5. 换绑
	_enet = enet
	_set_peer(_enet)
	# 6. 退出替换：解除抑制 + 复位闩锁
	_end_swap()
	return OK


## 连到一台服务器。失败（地址非法等）时返回非 OK 的 Error 并发一次 connection_failed()。
func join(address: String, port: int) -> Error:
	_begin_swap()
	_detach_multiplayer_peer()
	_release_current_peer()
	var enet := ENetMultiplayerPeer.new()
	var err := enet.create_client(address, port)
	if err != OK:
		# create_client 失败后这个 peer 并没有激活，同样不能 close，直接丢弃。
		_end_swap()
		_emit_connection_failed()
		return err
	_enet = enet
	_set_peer(_enet)
	_end_swap()
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


## 释放当前 peer：解绑它的信号 + 清空本层状态 + 关掉它。
##
## 关掉它之前，mp 必须已经解绑（见 _detach_multiplayer_peer），
## 否则 mp 还会 poll 这个已被关掉的 peer，引擎会打 ERROR。
func _release_current_peer() -> void:
	var old := _enet
	_enet = null
	_clear_peer_state()
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
