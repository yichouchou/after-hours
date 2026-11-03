extends SceneTree

## Task 6：Transport 抽象与 ENet 传输。
##
## 单进程双 Transport 的握手测试：
## 一个 host，一个 client，验证 peer_connected / peer_list / is_host。
##
## 断言分组：
##   1. 未启用时的初始状态（get_peer / is_host / peer_list / is_attached / get_peer_id）
##   2. host 创建；同端口二次 host 失败 → 非 OK 的 Error + connection_failed()
##   3. 握手：双方互相看到对方；peer_connected 两端都发；server_connected 只发一次
##   4. client 关闭 → host 收到 peer_disconnected
##   5. attach_to：挂上之后 poll() 不再驱动底层 peer；信号照常发出（attached 模式）
##   6. 闩锁复位：同一对象重试 / 重连时信号不被静默吞掉
##
## 【夹具修正】brief 第 53 行原断言写死「host 看到 peer 2」。
## Godot 4.7.2 实测：ENet 客户端的 unique id 是 create_client 时随机生成的 32 位整数
## （实测 2131996968），不是 Godot 3 时代的固定 2；只有服务器是 1。
## 所以这里改成「host 看到的那唯一一个 peer == client 自己的 peer id」，
## 并额外断言 peer_connected 信号带的就是同一个 id——语义没有被削弱，反而更强。
##
## 端口：27015（主握手）/ 27016（attach_to 用）/ 27017（闩锁用例），收尾全部 close() 释放。
##
## 注意：预期失败的调用（二次 host、非法地址 join）会触发引擎自身的 ERROR 日志，
## 包裹在 Engine.print_error_messages = false 里，保证测试输出干净。

const HOST_PORT := 27015
const ATTACH_PORT := 27016
const LATCH_PORT := 27017
const RETRY_PORT := 27018
const NEW2_PORT := 27019
const NEW3_PORT := 27020

var _host: ENetTransport
var _client: ENetTransport
var _attach_host: ENetTransport
var _attach_client: ENetTransport
var _latch_server: ENetTransport
var _latch_client: ENetTransport
var _retry_host: ENetTransport
var _retry_client: ENetTransport
var _new2_host: ENetTransport
var _new3_host: ENetTransport

var _fails := 0
var _total := 0

# 信号计数 / 记录
var _host_connected_ids: Array[int] = []
var _host_disconnected_ids: Array[int] = []
var _client_connected_ids: Array[int] = []
var _client_disconnected_ids: Array[int] = []
var _host_server_connected_count := 0
var _client_server_connected_count := 0
var _host_connection_failed_count := 0
var _client_connection_failed_count := 0
var _double_host_connection_failed_count := 0

# attach_to 用例的信号计数（C1：attached 模式下信号必须真的发出来）
var _attach_host_connected_ids: Array[int] = []
var _attach_client_connected_ids: Array[int] = []
var _attach_host_server_connected_count := 0
var _attach_client_server_connected_count := 0
var _attach_host_connection_failed_count := 0
var _attach_client_connection_failed_count := 0

# 闩锁复位用例的信号计数
var _retry_failure_count := 0
var _latch_server_connected_count := 0
var _latch_failure_count := 0

# 重新 join / 失败路径 / 重新 attach 用例的信号计数
var _retry_connected_ids: Array[int] = []
var _retry_server_connected_count := 0
var _retry_connection_failed_count := 0
var _new3_server_connected_count := 0
var _new3_connection_failed_count := 0

# 已经 close 过的 peer，避免二次 close 触发引擎 ERR_FAIL_COND
var _closed_peers: Array[MultiplayerPeer] = []


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	# ==================================================================
	# 1. 未启用时的初始状态
	# ==================================================================
	var fresh := ENetTransport.new()
	_fails += _check(fresh.get_peer() == null, "初始 get_peer() 为 null")
	_fails += _check(not fresh.is_host(), "初始 is_host() 为 false")
	_fails += _check(fresh.peer_list() == [], "初始 peer_list() 为空数组，实际 %s" % str(fresh.peer_list()))
	_fails += _check(not fresh.is_attached(), "初始 is_attached() 为 false")
	_fails += _check(fresh.get_peer_id() == 1, "初始 get_peer_id() 为 1（_peer == null 时的既定行为）")

	# ==================================================================
	# 2. host 创建
	# ==================================================================
	_host = ENetTransport.new()
	_host.peer_connected.connect(func(id): _host_connected_ids.append(id))
	_host.peer_disconnected.connect(func(id): _host_disconnected_ids.append(id))
	_host.server_connected.connect(func(): _host_server_connected_count += 1)
	_host.connection_failed.connect(func(): _host_connection_failed_count += 1)

	var e := _host.host(HOST_PORT, 4)
	_fails += _check(e == OK, "host 创建成功")
	_fails += _check(_host.is_host(), "host.is_host() 为 true")
	_fails += _check(_host.get_peer_id() == 1, "host peer id 为 1")
	_fails += _check(_host.get_peer() != null, "host 创建后 get_peer() 非 null")
	_fails += _check(_host.peer_list().is_empty(), "host 创建后还没有任何 peer")

	# --- 同一端口二次 host：必须失败并发出 connection_failed() ---
	var second := ENetTransport.new()
	second.connection_failed.connect(func(): _double_host_connection_failed_count += 1)
	# 预期失败：压掉引擎自身的 ERROR 日志，保持测试输出干净。
	Engine.print_error_messages = false
	var e_second := second.host(HOST_PORT, 4)
	Engine.print_error_messages = true
	_fails += _check(e_second != OK, "同一端口二次 host 返回非 OK 的 Error（实际 %d）" % e_second)
	_fails += _check(_double_host_connection_failed_count == 1,
		"同一端口二次 host 发出 connection_failed()（实际 %d 次）" % _double_host_connection_failed_count)
	_fails += _check(second.get_peer() == null, "二次 host 失败后 get_peer() 仍为 null")
	_fails += _check(not second.is_host(), "二次 host 失败后 is_host() 仍为 false")
	_fails += _check(_host.get_peer() != null and _host.is_host(), "二次 host 失败不影响第一个 host")

	# ==================================================================
	# 3. client 连接 + 握手
	# ==================================================================
	_client = ENetTransport.new()
	_client.peer_connected.connect(func(id): _client_connected_ids.append(id))
	_client.peer_disconnected.connect(func(id): _client_disconnected_ids.append(id))
	_client.server_connected.connect(func(): _client_server_connected_count += 1)
	_client.connection_failed.connect(func(): _client_connection_failed_count += 1)

	var e2 := _client.join("127.0.0.1", HOST_PORT)
	_fails += _check(e2 == OK, "client 连接请求发出")
	_fails += _check(not _client.is_host(), "client.is_host() 为 false")
	_fails += _check(_client.get_peer_id() != 1, "client 的 peer id 不是 1（不是服务器），实际 %d" % _client.get_peer_id())

	var client_id := _client.get_peer_id()

	var connected := false
	for i in 240:
		_host.poll()
		_client.poll()
		if _host.peer_list().size() == 1 and _client.peer_list().size() == 1:
			connected = true
			break
		await process_frame

	_fails += _check(connected, "双方互相看到对方")
	_fails += _check(_host.peer_list() == [client_id],
		"host 看到 peer %d（brief 写死 2，但 4.7.2 的客户端 id 是随机的），实际 %s"
		% [client_id, str(_host.peer_list())])
	_fails += _check(_client.peer_list() == [1], "client 看到 peer 1，实际 %s" % str(_client.peer_list()))
	_fails += _check(not _client.is_host(), "client.is_host() 为 false")

	# --- 4 个信号的断言 ---
	_fails += _check(_host_connected_ids == [client_id],
		"host 收到 peer_connected(%d)（客户端 id），实际 %s" % [client_id, str(_host_connected_ids)])
	_fails += _check(_client_connected_ids == [1],
		"client 收到 peer_connected(1)（服务器 id），实际 %s" % str(_client_connected_ids))
	_fails += _check(_client_server_connected_count == 1,
		"client 收到 server_connected() 恰好 1 次，实际 %d 次" % _client_server_connected_count)
	_fails += _check(_host_server_connected_count == 0,
		"host 侧不发 server_connected()（那是 client 专用信号），实际 %d 次" % _host_server_connected_count)
	_fails += _check(_host_connection_failed_count == 0,
		"握手过程中 host 不发 connection_failed()，实际 %d 次" % _host_connection_failed_count)

	# 重复 poll 不得重复发 server_connected()
	for i in 30:
		_host.poll()
		_client.poll()
		await process_frame
	_fails += _check(_client_server_connected_count == 1,
		"重复 poll 后 server_connected() 仍然只有 1 次，实际 %d 次" % _client_server_connected_count)
	_fails += _check(_host_connected_ids.size() == 1,
		"重复 poll 后 host 的 peer_connected 不重复发，实际 %s" % str(_host_connected_ids))

	# ==================================================================
	# 4. client 关闭 → host 收到 peer_disconnected
	# ==================================================================
	_close_peer(_client.get_peer())
	_client.poll()   # 断开后 transport.poll() 应发出 connection_failed，且不能再 poll 已关闭的 peer
	_fails += _check(_client_connection_failed_count == 1,
		"client 已连接后断开 → connection_failed() 发 1 次，实际 %d 次" % _client_connection_failed_count)

	var disconnected := false
	for i in 120:
		_host.poll()
		if _host_disconnected_ids.size() == 1:
			disconnected = true
			break
		await process_frame
	_fails += _check(disconnected, "host 收到了 peer_disconnected")
	_fails += _check(_host_disconnected_ids == [client_id],
		"host 收到 peer_disconnected(%d)，实际 %s" % [client_id, str(_host_disconnected_ids)])
	_fails += _check(_host.peer_list().is_empty(),
		"client 断开后 host.peer_list() 变空，实际 %s" % str(_host.peer_list()))

	# ==================================================================
	# 5. attach_to 行为
	#    用独立的 MultiplayerAPI（不碰 SceneTree 自己的 multiplayer，
	#    否则引擎会自动 poll 那个 peer，干扰握手断言）。
	# ==================================================================
	var mp := MultiplayerAPI.create_default_interface()
	_attach_host = ENetTransport.new()
	_attach_host.peer_connected.connect(func(id): _attach_host_connected_ids.append(id))
	_attach_host.server_connected.connect(func(): _attach_host_server_connected_count += 1)
	_attach_host.connection_failed.connect(func(): _attach_host_connection_failed_count += 1)
	var e_ah := _attach_host.host(ATTACH_PORT, 4)
	_fails += _check(e_ah == OK, "attach 用例的 host 创建成功")

	_attach_client = ENetTransport.new()
	_attach_client.peer_connected.connect(func(id): _attach_client_connected_ids.append(id))
	_attach_client.server_connected.connect(func(): _attach_client_server_connected_count += 1)
	_attach_client.connection_failed.connect(func(): _attach_client_connection_failed_count += 1)
	var e_ac := _attach_client.join("127.0.0.1", ATTACH_PORT)
	_fails += _check(e_ac == OK, "attach 用例的 client 连接请求发出")

	_attach_client.attach_to(mp)
	_fails += _check(_attach_client.is_attached(), "attach_to 之后 is_attached() 为 true")
	_fails += _check(mp.multiplayer_peer == _attach_client.get_peer(),
		"attach_to 之后 mp.multiplayer_peer == get_peer()")
	_fails += _check(not _attach_host.is_attached(), "没 attach 的 transport is_attached() 仍为 false")
	_fails += _check(_attach_client.get_peer() != null, "attach_to 之后 get_peer() 非 null")

	# 阶段一：只调 transport.poll()（不调 mp.poll()）。
	# 挂载之后 transport.poll() 不得再驱动底层 peer：
	# 客户端 peer 应一直停在 CONNECTING（没人 poll 它），host 也看不到它。
	for i in 60:
		_attach_host.poll()
		_attach_client.poll()
		await process_frame
	_fails += _check(_attach_client.get_peer().get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING,
		"已挂载后 transport.poll() 不再驱动底层 peer（peer 仍停在 CONNECTING，实际 %d）"
		% _attach_client.get_peer().get_connection_status())
	_fails += _check(_attach_host.peer_list().is_empty(),
		"已挂载期间 client 并没有真的连上（host 看不到 peer），实际 %s" % str(_attach_host.peer_list()))
	_fails += _check(_attach_client.peer_list().is_empty(),
		"已挂载期间 transport 没有发出 peer_connected，实际 %s" % str(_attach_client.peer_list()))
	_fails += _check(_attach_client_server_connected_count == 0,
		"已挂载期间 transport 没有发出 server_connected，实际 %d 次" % _attach_client_server_connected_count)

	# 阶段二：改由 MultiplayerAPI 驱动 → 连接建立，信号照常发出。
	# 这一阶段**不调** _attach_client.poll()：server_connected 只能来自
	# MultiplayerAPI.connected_to_server —— 证明 attached 模式下不依赖上层
	# 每帧调用 transport.poll()。
	var mp_connected := false
	for i in 120:
		_attach_host.poll()
		mp.poll()
		await process_frame
		if _attach_client.get_peer().get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			mp_connected = true
			break
	_fails += _check(mp_connected, "由 MultiplayerAPI 驱动 poll 后连接建立")
	_fails += _check(_attach_client.peer_list() == [1],
		"已挂载时 peer_connected(1) 照常发出，peer_list 实际 %s" % str(_attach_client.peer_list()))
	_fails += _check(_attach_client_server_connected_count == 1,
		"attached 模式下 server_connected() 恰好发 1 次，实际 %d 次" % _attach_client_server_connected_count)
	_fails += _check(_attach_host_server_connected_count == 0,
		"attached 模式下 host 不发 server_connected()，实际 %d 次" % _attach_host_server_connected_count)

	# host 侧的 peer_connected 比 client 侧晚一轮（ENet 的连接确认是一次往返：
	# 探针实测顺序是 client 先收到 peer_connected(1)，host 下一轮才发），
	# 所以这里再多等几帧，等 host 侧也看到 client。
	var host_sees_client := false
	for i in 60:
		_attach_host.poll()
		mp.poll()
		await process_frame
		if _attach_host.peer_list().size() == 1:
			host_sees_client = true
			break
	_fails += _check(host_sees_client,
		"已挂载时 host 也看得到 client，host.peer_list 实际 %s" % str(_attach_host.peer_list()))

	# 阶段三：房主主动断开这个 client。
	# 必须用 disconnect_peer（优雅断开），客户端 1 帧内就能发现；
	# 直接 close() 房主的 peer 不会通知客户端（实测客户端要等 ENet 超时 ≈31.5s）。
	var attach_client_id := _attach_client.get_peer_id()
	_attach_host.get_peer().disconnect_peer(attach_client_id)
	var dropped := false
	for i in 60:
		_attach_host.poll()
		mp.poll()
		await process_frame
		if _attach_client_connection_failed_count == 1:
			dropped = true
			break
	_fails += _check(dropped, "attached 模式下掉线后 transport 发出 connection_failed()")
	_fails += _check(_attach_client_connection_failed_count == 1,
		"attached 模式下 connection_failed() 恰好发 1 次，实际 %d 次" % _attach_client_connection_failed_count)
	_fails += _check(_attach_client_server_connected_count == 1,
		"掉线后 server_connected 不会被重复发，实际 %d 次" % _attach_client_server_connected_count)

	# ==================================================================
	# 6. 闩锁复位：同一个对象重试 / 重连时，信号不能被静默吞掉
	# ==================================================================
	# (a) 同一对象连续两次 join 失败 → connection_failed 发 2 次。
	#     用非法地址让 create_client 立刻失败：连死端口要等 ENet 的
	#     connect timeout（实测 ≈31.5s），不在 --quit-after 600 的预算内。
	var retry := ENetTransport.new()
	retry.connection_failed.connect(func(): _retry_failure_count += 1)
	Engine.print_error_messages = false
	var re1 := retry.join("不是一个服务器地址", HOST_PORT)
	var re2 := retry.join("不是一个服务器地址", HOST_PORT)
	Engine.print_error_messages = true
	_fails += _check(re1 != OK, "第一次非法地址 join 返回非 OK 的 Error（实际 %d）" % re1)
	_fails += _check(re2 != OK, "第二次非法地址 join 返回非 OK 的 Error（实际 %d）" % re2)
	_fails += _check(_retry_failure_count == 2,
		"同一对象连续两次 join 失败 → connection_failed 发 2 次，实际 %d 次" % _retry_failure_count)

	# (b) 同一对象：join 成功 → 掉线 → 再 join 成功 → server_connected 发 2 次。
	_latch_server = ENetTransport.new()
	var e_ls := _latch_server.host(LATCH_PORT, 4)
	_fails += _check(e_ls == OK, "闩锁用例的 host 创建成功")

	_latch_client = ENetTransport.new()
	_latch_client.server_connected.connect(func(): _latch_server_connected_count += 1)
	_latch_client.connection_failed.connect(func(): _latch_failure_count += 1)

	var j1 := _latch_client.join("127.0.0.1", LATCH_PORT)
	_fails += _check(j1 == OK, "闩锁用例第一次 join 成功")
	for i in 120:
		_latch_server.poll()
		_latch_client.poll()
		if _latch_server_connected_count == 1:
			break
		await process_frame
	_fails += _check(_latch_server_connected_count == 1,
		"第一次 join 成功后 server_connected 发 1 次，实际 %d 次" % _latch_server_connected_count)

	# 掉线：关掉客户端自己的 peer，再 poll 一次
	# （poll 会发现 DISCONNECTED → 发 connection_failed，且不会再碰已关闭的 peer）。
	_close_peer(_latch_client.get_peer())
	_latch_client.poll()
	_fails += _check(_latch_failure_count == 1,
		"掉线后 connection_failed 发 1 次，实际 %d 次" % _latch_failure_count)

	# 同一个对象再 join 一次 → 闩锁复位 → server_connected 应该再发一次。
	var j2 := _latch_client.join("127.0.0.1", LATCH_PORT)
	_fails += _check(j2 == OK, "闩锁用例第二次 join 成功")
	for i in 120:
		_latch_server.poll()
		_latch_client.poll()
		if _latch_server_connected_count == 2:
			break
		await process_frame
	_fails += _check(_latch_server_connected_count == 2,
		"同一对象重连成功后 server_connected 再发 1 次（共 2 次），实际 %d 次" % _latch_server_connected_count)

	# ==================================================================
	# 7. attached 模式下同一对象重试 join()（NEW-1）
	#    mp 必须跟着换绑到新 peer，否则新 peer 无人 poll，连接永远建立不起来；
	#    而且换绑顺序不对的话，mp 会因为「旧连接被本层关掉」报出一条伪 connection_failed。
	# ==================================================================
	var retry_mp := MultiplayerAPI.create_default_interface()
	_retry_host = ENetTransport.new()
	var e_rh := _retry_host.host(RETRY_PORT, 4)
	_fails += _check(e_rh == OK, "重试用例的 host 创建成功")

	_retry_client = ENetTransport.new()
	_retry_client.peer_connected.connect(func(id): _retry_connected_ids.append(id))
	_retry_client.server_connected.connect(func(): _retry_server_connected_count += 1)
	_retry_client.connection_failed.connect(func(): _retry_connection_failed_count += 1)
	var e_rj := _retry_client.join("127.0.0.1", RETRY_PORT)
	_fails += _check(e_rj == OK, "重试用例第一次 join 成功")
	_retry_client.attach_to(retry_mp)
	_fails += _check(retry_mp.multiplayer_peer == _retry_client.get_peer(),
		"重试用例：attach 之后 mp 绑定的是当前 peer")

	for i in 120:
		_retry_host.poll()
		retry_mp.poll()
		await process_frame
		if _retry_server_connected_count == 1:
			break
	_fails += _check(_retry_server_connected_count == 1,
		"重试用例第一次连接成功，server_connected 发 1 次，实际 %d 次" % _retry_server_connected_count)

	# 同一个对象重新 join()：mp 必须换绑到新 peer，新 peer 才能被驱动。
	var e_rejoin := _retry_client.join("127.0.0.1", RETRY_PORT)
	_fails += _check(e_rejoin == OK, "attached 模式重新 join 返回 OK")
	for i in 120:
		_retry_host.poll()
		retry_mp.poll()
		await process_frame
		if _retry_server_connected_count == 2:
			break
	_fails += _check(_retry_server_connected_count == 2,
		"attached 模式重新 join 后 server_connected 再发 1 次（共 2 次），实际 %d 次" % _retry_server_connected_count)
	_fails += _check(_retry_client.get_peer().get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED,
		"attached 模式重新 join 后新 peer 真的连上了（status=%d）"
		% _retry_client.get_peer().get_connection_status())
	_fails += _check(retry_mp.multiplayer_peer == _retry_client.get_peer(),
		"attached 模式重新 join 后 mp 绑定的是新 peer")
	_fails += _check(_retry_connection_failed_count == 0,
		"attached 模式重新 join 过程中不得产生伪 connection_failed，实际 %d 次" % _retry_connection_failed_count)

	# ==================================================================
	# 8. 失败路径状态自洽（NEW-2）
	#    join 失败之后：get_peer() == null、get_peer_id() == 1、is_host() == false，
	#    而且不能留下一个「已被本层关掉」的旧 peer 让上层拿到
	#    （否则 get_peer_id() 会返回 0，既不是合法 peer id 也不是约定的 1）。
	# ==================================================================
	_new2_host = ENetTransport.new()
	var e_n2 := _new2_host.host(NEW2_PORT, 4)
	_fails += _check(e_n2 == OK, "失败路径用例的 host 创建成功")
	_fails += _check(_new2_host.get_peer() != null, "失败路径用例：host 成功时 get_peer() 非 null")

	# 预期失败：压掉引擎自身的 ERROR 日志，保持测试输出干净。
	Engine.print_error_messages = false
	var e_bad := _new2_host.join("不是一个服务器地址", NEW2_PORT)
	Engine.print_error_messages = true
	_fails += _check(e_bad != OK, "失败路径用例：非法地址 join 返回非 OK 的 Error（实际 %d）" % e_bad)
	# 这三个调用如果落在已被关掉的旧 peer 上，引擎会打 ERROR；
	# 外面包一层压制以保持输出干净（真正的判据是下面三个返回值断言：
	# 旧 peer 的 get_unique_id() 返回 0，与约定的 1 不同）。
	Engine.print_error_messages = false
	var peer_after_fail := _new2_host.get_peer()
	var id_after_fail := _new2_host.get_peer_id()
	var host_after_fail := _new2_host.is_host()
	Engine.print_error_messages = true
	_fails += _check(peer_after_fail == null, "失败路径：join 失败后 get_peer() == null")
	_fails += _check(id_after_fail == 1,
		"失败路径：join 失败后 get_peer_id() == 1（约定的无 peer 值），实际 %d" % id_after_fail)
	_fails += _check(not host_after_fail, "失败路径：join 失败后 is_host() == false")
	_fails += _check(_new2_host.peer_list().is_empty(),
		"失败路径：join 失败后 peer_list() 为空，实际 %s" % str(_new2_host.peer_list()))

	# ==================================================================
	# 9. 重新 attach 到新的 mp（NEW-3）
	#    旧 mp 必须解除信号绑定：不再转发，而且 mp 持有的 transport 强引用会释放。
	# ==================================================================
	var mp_a := MultiplayerAPI.create_default_interface()
	var mp_b := MultiplayerAPI.create_default_interface()
	_new3_host = ENetTransport.new()
	var e_n3 := _new3_host.host(NEW3_PORT, 4)
	_fails += _check(e_n3 == OK, "重新 attach 用例的 host 创建成功")
	_new3_host.server_connected.connect(func(): _new3_server_connected_count += 1)
	_new3_host.connection_failed.connect(func(): _new3_connection_failed_count += 1)
	_new3_host.attach_to(mp_a)
	_new3_host.attach_to(mp_b)
	# 旧 mp 不再转发
	mp_a.emit_signal("connected_to_server")
	mp_a.emit_signal("connection_failed")
	_fails += _check(_new3_server_connected_count == 0,
		"重新 attach 后旧 mp 不再转发 server_connected，实际 %d 次" % _new3_server_connected_count)
	_fails += _check(_new3_connection_failed_count == 0,
		"重新 attach 后旧 mp 不再转发 connection_failed，实际 %d 次" % _new3_connection_failed_count)
	# 新 mp 仍然转发
	mp_b.emit_signal("connected_to_server")
	_fails += _check(_new3_server_connected_count == 1,
		"重新 attach 后新 mp 仍然转发 server_connected，实际 %d 次" % _new3_server_connected_count)

	# ==================================================================
	# 10. 收尾：关掉所有 peer，释放端口
	# ==================================================================
	_close_peer(_retry_client.get_peer())
	_close_peer(_retry_host.get_peer())
	_close_peer(_new2_host.get_peer())
	_close_peer(_new3_host.get_peer())
	_close_peer(_attach_client.get_peer())
	_close_peer(_attach_host.get_peer())
	_close_peer(_latch_client.get_peer())
	_close_peer(_latch_server.get_peer())
	_close_peer(_host.get_peer())

	print("")
	print("断言总数：%d" % _total)
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


## close 一个 peer，并记账，避免二次 close 触发引擎 ERR_FAIL_COND 报错。
func _close_peer(p: MultiplayerPeer) -> void:
	if p == null or p in _closed_peers:
		return
	_closed_peers.append(p)
	p.close()


func _check(ok: bool, what: String) -> int:
	_total += 1
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
