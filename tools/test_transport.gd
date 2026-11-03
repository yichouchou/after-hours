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
##   5. attach_to：挂上之后 poll() 不再驱动底层 peer（改由 MultiplayerAPI 驱动）
##
## 【夹具修正】brief 第 53 行原断言写死「host 看到 peer 2」。
## Godot 4.7.2 实测：ENet 客户端的 unique id 是 create_client 时随机生成的 32 位整数
## （实测 2131996968），不是 Godot 3 时代的固定 2；只有服务器是 1。
## 所以这里改成「host 看到的那唯一一个 peer == client 自己的 peer id」，
## 并额外断言 peer_connected 信号带的就是同一个 id——语义没有被削弱，反而更强。
##
## 端口：27015（主握手）/ 27016（attach_to 用），测试收尾全部 close() 释放。

const HOST_PORT := 27015
const ATTACH_PORT := 27016

var _host: ENetTransport
var _client: ENetTransport
var _attach_host: ENetTransport
var _attach_client: ENetTransport

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
	var e_second := second.host(HOST_PORT, 4)
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
	var e_ah := _attach_host.host(ATTACH_PORT, 4)
	_fails += _check(e_ah == OK, "attach 用例的 host 创建成功")

	_attach_client = ENetTransport.new()
	var e_ac := _attach_client.join("127.0.0.1", ATTACH_PORT)
	_fails += _check(e_ac == OK, "attach 用例的 client 连接请求发出")

	_attach_client.attach_to(mp)
	_fails += _check(_attach_client.is_attached(), "attach_to 之后 is_attached() 为 true")
	_fails += _check(mp.multiplayer_peer == _attach_client.get_peer(),
		"attach_to 之后 mp.multiplayer_peer == get_peer()")
	_fails += _check(not _attach_host.is_attached(), "没 attach 的 transport is_attached() 仍为 false")
	_fails += _check(_attach_client.get_peer() != null, "attach_to 之后 get_peer() 非 null")

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

	# 改由 MultiplayerAPI 驱动 → 连接建立，信号照常发出。
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

	# ==================================================================
	# 6. 收尾：关掉所有 peer，释放端口
	# ==================================================================
	_close_peer(_attach_client.get_peer())
	_close_peer(_attach_host.get_peer())
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
