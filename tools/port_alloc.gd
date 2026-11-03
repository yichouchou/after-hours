extends RefCounted

## Task 7 修复轮 3（F3）：测试端口的**动态分配**工具。
##
## ------------------------------------------------------------------
## 【为什么需要它】
## ------------------------------------------------------------------
## 固定端口 = 隐含「全局只有我一个人跑」的假设。而 SDD 流程里
## 「控制器跑统一入口」与「复审子代理跑测试」是**必然并发**的
## → 这个假设必然被打破 → 固定端口必然被抢 → 产生**假失败**。
##
## 实测（控制器 + 上一位复审子代理，两边都撞上过）：
##   * 端口 27040 被另一个进程占着 → tools/test_session_link.gd
##     的 12 条断言连锁失败、退出码 1；端口一释放，**立刻恢复 42/42 全绿**。
##   * 复审子代理首跑统一入口得到 7/9，单独重跑那两个文件全绿，重跑全量 9/9。
##
## → 所以测试端口必须在运行时动态分配，且**互不干扰**。
##
## ------------------------------------------------------------------
## 【★ 核心裁决：端口的裁决权归「真实的服务端 socket」】
## ------------------------------------------------------------------
## **禁止「探测 → 关闭 → 盲信」**：用一个探测 socket bind() 一下端口、
## 成功就认为这个端口可用、close 掉探测 socket、把端口号交给真正要 bind 的地方 ——
## **这个做法是错的**：探测与真实绑定之间存在**竞态窗口**，
## 两个并发进程可能**同时**探测到同一个端口、都以为它是空的，
## 然后其中一个真实绑定失败 → 测试失败。
## （那只是把「固定端口冲突」换成了「概率性冲突」。）
##
## → 所以本文件**不做探测**、**不持有任何 socket**、**不代劳绑定**：
##   它只提供「候选端口序列」。
##   绑定必须由调用方用**真实的** ENetTransport / Session 去完成：
##     * 绑定成功 → 这个端口可用；
##     * 绑定失败 → **换下一个候选**；
##     * 候选用尽 → **明确失败**，严禁静默回退到任何固定端口。
##
## ------------------------------------------------------------------
## 【★ 不写 class_name】
## ------------------------------------------------------------------
## Task 7 已经踩过「class_name 与同名 autoload 互斥」的坑
## （Parse Error: Class "Session" hides an autoload singleton）。
## 测试工具类没有理由进全局命名空间。
## → 调用方一律用：const PortAlloc := preload("res://tools/port_alloc.gd")
##
## ------------------------------------------------------------------
## 【本文件不 preload 任何游戏脚本、不出现 get_tree() / get_node()】
## 它是个纯工具。

## 候选端口段的基准（27100 起）。
const BASE := 27100

## 候选端口段的长度（27100–27299，共 200 个）。
const SPAN := 200

## 必须避开的**已固定占用**端口：
##   27015–27024：Task 6（tools/test_transport.gd 的历史固定端口）
##   27030–27034：Task 7 单进程（tools/test_session.gd 的历史固定端口）
##   27040/27041：Task 7 双进程（tools/test_session_link.gd 的历史固定端口）
##   27050     ：Task 12 预留
##
## 这些端口**只是历史遗留**，本轮起测试不再使用它们。
## 保留这份清单是为了「万一有人再写死端口」时能被断言挡住。
const RESERVED := [
	27015, 27016, 27017, 27018, 27019, 27020, 27021, 27022, 27023, 27024,
	27030, 27031, 27032, 27033, 27034,
	27040, 27041,
	27050,
]


## 已固定占用、必须避开的端口（副本）。
static func reserved() -> Array[int]:
	var out: Array[int] = []
	for p in RESERVED:
		out.append(int(p))
	return out


## 这个端口是不是「已固定占用」的端口？
static func is_reserved(port: int) -> bool:
	return RESERVED.has(port)


## 候选端口序列：随机起点 + 线性递增 + 末尾回绕，长度 = span，**无重复**。
##
## 起点随机化**不是**为了正确性（正确性由「真实绑定裁决」保证），
## 只是为了减少两个并发进程每次都从同一个候选开始造成的无谓重试。
##
## start_offset < 0 → **随机**起点；
## start_offset >= 0 → 从 base + (start_offset % span) 开始的**确定性**序列
##   （父进程把 (base, span) 交给子进程时用这个 —— 子进程必须按父进程给的顺序试）。
static func candidates(base: int = BASE, span: int = SPAN, start_offset: int = -1) -> Array[int]:
	var out: Array[int] = []
	if span <= 0:
		return out
	var off := start_offset
	if off < 0:
		off = _rng().randi_range(0, span - 1)
	off = posmod(off, span)
	for i in span:
		out.append(base + posmod(off + i, span))
	return out


## 取一个「起点 + 长度」都落在候选段内的**线性窗口**（起点随机）。
##
## 用途：父进程把 (base, span) 交给子进程时，子进程要按**确定性**顺序逐个尝试
## base, base+1, …, base+span-1（**不允许**在连不上时换端口 —— 那会连到别人的服务器）。
## 窗口必须整体落在 [BASE, BASE+SPAN) 内，否则会跑到保留端口段上去。
static func window(count: int) -> Array[int]:
	var n := clampi(count, 1, SPAN)
	var start := BASE + _rng().randi_range(0, SPAN - n)
	var out: Array[int] = []
	for i in n:
		out.append(start + i)
	return out


## 随机数发生器（每次调用都重新播种 → 跨进程也不会每次都撞同一个起点）。
static func _rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng


# ------------------------------------------------------------------
# 实例侧：游标式分配器
# ------------------------------------------------------------------

## 候选序列（已剔除「已固定占用」的端口）。
var _seq: Array[int] = []

## 游标（下一个要试的候选的下标）。
var _cursor := 0


func _init(base: int = BASE, span: int = SPAN, start_offset: int = -1) -> void:
	for p in candidates(base, span, start_offset):
		if not is_reserved(p):
			_seq.append(p)


## 下一个**还没试过**的候选端口。
##
## 用法：拿候选 → **真实绑定** → 失败就再 next()。
## 候选用尽 → 返回 -1（配合 exhausted() 判断 → **必须明确失败**，
## 严禁静默回退到任何固定端口）。
func next() -> int:
	if _cursor >= _seq.size():
		return -1
	var p: int = _seq[_cursor]
	_cursor += 1
	return p


## 候选是不是已经用完了（用完就必须明确失败）。
func exhausted() -> bool:
	return _cursor >= _seq.size()


## 还剩几个候选没试（诊断用）。
func remaining() -> int:
	return maxi(0, _seq.size() - _cursor)
