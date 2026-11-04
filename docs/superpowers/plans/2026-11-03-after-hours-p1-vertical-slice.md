# After Hours — Phase 1 可玩垂直切片 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个可玩的垂直切片——本地双窗口能一起开局、领捣蛋清单、执行捣蛋、被守卫抓到并送回出生点、天亮后结算。

**Architecture:** 玩法逻辑全部写成**纯 GDScript 类**（`RefCounted`/`Resource`，不依赖场景树），因此可以在 headless 下直接单元测试；Node 只做薄封装。联网走 Transport 抽象层，P1 只实现 ENet，Steam 传输留到 P2。混合权威：玩家移动由拥有者权威同步，捣蛋裁决与守卫 AI 由房主权威。

**Tech Stack:** Godot 4.7.2-stable / GDScript / ENetMultiplayerPeer / Python 3.13 + Pillow（占位素材）

## Global Constraints

以下约束**每个任务都隐含适用**，不得违反：

- 引擎版本固定 `4.7.2.stable`；渲染后端固定 `gl_compatibility`
- 逻辑分辨率固定 `640×360`，窗口 `1280×720`，`stretch/mode="canvas_items"`，`stretch/aspect="keep"`
- **手绘风，纹理过滤用线性（Linear），不是 Nearest** —— 与 Pixel Town 的像素管线刻意区分
- 玩法逻辑文件（`scripts/game/**`）**禁止**引用 `get_tree()` / `get_node()` / 场景节点；它们必须是纯函数或纯状态对象
- **Gameplay 层禁止出现任何 `Steam.` 调用**；Steam 代码只允许出现在 `scripts/net/steam_transport.gd`
- 测试一律用 headless 脚本，退出码 0 = 通过，1 = 失败。
- **规范命令链是两步，顺序不能换**（缺第一步会导致干净检出上 `load()` 抛
  "No loader found for resource"，每个 PNG 一条 ERROR）：
  1. `godot --headless --path <proj> --import`
  2. `godot --headless --path <proj> --quit-after 600 --script res://tools/test_<name>.gd`
- 项目根的 **`tools/run_tests.ps1` 是全项目唯一的测试入口**，固化上面两步并依次跑全部测试。
- **跑测试必须带 `--quit-after N`（N 取 600，约 10 秒）**。
  原因（Task 1 修复轮 2 实测）：本测试形态（`extends SceneTree` + `await` + `quit()`）在脚本发生
  运行时错误时协程会被中断、`quit()` 永不执行，进程会**永久挂起而不是失败退出**。
  `--quit-after` 是命令行侧保险，不需改动任何测试代码。
- **判定测试通过 = 退出码为 0 且输出含 `TEST PASSED`**（两者都要看）。
  `--quit-after` 兜底退出时退出码是 0，脚本中途抛错时输出里不会有 `TEST PASSED`。
- 每个任务结束必须 `git commit`
- **零失败惩罚**：任何被测逻辑都不得产生"扣分/淘汰/扣命"的返回值
- 命名：类名用 PascalCase，文件名用 snake_case，私有成员前缀 `_`

### 捣蛋清单生成的规则口径（Task 3 审查裁决，2026-11-04）

Task 3 的任务书自身存在三处矛盾（自带实现与自带测试互斥、返回类型不可表达、整副牌上限与牌数需求不可兼容），
已由审查独立实测确认并在此**落笔裁决**，后续任务（尤其 Task 7 发牌展示、Task 10 房主裁决）必须按此执行，
不要再重新推导：

- **规则 3/4/5 的作用域 = 每份清单各自成立**（不是整副牌一起成立）。
  理由：规则 1 要求 6 人局每人 5 张 = 30 张牌，而 P1 只有 10 条行为（设计文档全量 20 条也只够 4 人局铺满），
  「整副牌不重复发牌」在 4-6 人局**数学上不可实现**，故整副牌读法被排除。
- **规则 6 = 每份清单两两不同，按「集合」口径判定**（两份清单包含的行为**集合**不得相同，顺序无关）。
  这不等于「整副牌不重复发牌」：同一张捣蛋牌可以同时出现在多名玩家的清单里，5-6 人局不可避免。
  Task 10 的房主裁决必须给出**先到先得**的归属规则，且**落败方不扣分**（零失败惩罚）。
  集合口径在数学上可达（10 条行为的 5 张合法集合共 138 个，`_build_hand` 可达 87 个，6 人局只需 6 个互不相同）。
- **`MischiefDeck.generate()` 返回类型是 `Array[Array]`，不是 `Array[Array[Mischief]]`**：
  Godot 4.7.2 不支持嵌套带类型数组（解析期报 "Nested typed collections are not supported."）。
  调用侧写 `var deals := MischiefDeck.generate(...)` 或 `var deals: Array[Array] = ...` 都可以。

### 联网层的既定裁决（Task 6 / Task 7，2026-11-04）

- **大厅名单一律以房主为权威**：Godot 4 的 ENet server-relay 下，**客户端侧的 `Transport.peer_list()` 只含服务器（id 1）**，
  relay peer 只在 `MultiplayerAPI.get_peers()` 可见 → 客户端用本地 `peer_list()` 算人数，**3 人以上必错**。
  → 名单由房主维护并**广播**；客户端以收到的名单为准。
- **清单必须定向发给本人**：房主生成清单后**按 peer id 定向发送**（每个客户端只拿到自己那一份），
  不能把整副牌广播出去（否则客户端能看见别人的清单）。
- **成员表以玩家 id 为键，不用 peer id**：ENet 客户端 peer id 是**随机 32 位数**，且**重连会换一个新的 peer id**。
- **Session 必须自带连接超时兜底**：ENet 的 connect timeout 不可配置，「连不上服务器」的失败信号实测要 ≈31.5 秒才发出
  （远超 `--quit-after 600`）→ Session 用 Timer 兜底，超时后主动 `close()` peer。
- **踢人 / 通知对端必须用 `disconnect_peer()`**：server 侧 `close()` **不会**通知 client
  （实测 client 仍停在 CONNECTED 120 帧）；`disconnect_peer(id)` 实测 1 帧内对端即知情。
- **重连时对端收不到任何 `peer_disconnected`**：旧 peer 的事件绑定在 close 之前就被解开了（不是被抑制标志挡掉的）。
- **`attach_to()` 必须在 host/join 成功之后调用**（`_peer == null` 时 `attach_to()` 是静默空操作）；
  但**重试不需要重新 `attach_to()`**（join 成功会自动把 mp 换绑到新 peer）。
- **`Session` 脚本不带 `class_name`**，autoload 名字就是 `Session`。
  原因（Task 7 实测）：Godot 4.7.2 里 `class_name Session` + 同名 autoload **互斥** ——
  报 `Parse Error: Class "Session" hides an autoload singleton`，autoload 加载失败、项目起不来。
  去掉 `class_name` 后，autoload 名字 `Session` 同时充当**全局标识符与类型**（Godot 4 标准写法）。
  → 代价：**`Session.new()` 不可用**（autoload 标识符不能当表达式用），
  需要实例化时用 `preload("res://scripts/net/session.gd").new()`（测试就是这么做的）。
- **网络载荷必须是纯数据**：`Mischief` 是 `Resource` 且由 `Mischief.new()` 运行时创建（无 `resource_path`），
  **不可被 RPC 编码** → 发清单时必须先转成**基础类型字典**（`id/title/category/target_tag/needs_partner/duration/points`），
  客户端收到后**本地重建** `Mischief` 对象。
  `Session.deal()` 在房主与客户端两端都返回 `Mischief` 对象的数组，调用方（Task 10 裁决 / Task 11 HUD）不需要知道线格式。
- **清单的线格式字段清单固定为**（Task 7 审查裁决，下游不许各自发明）：
  `{"id": String, "title": String, "category": String, "target_tag": String,
    "needs_partner": bool, "duration": float, "points": int}`
  —— 与 `Mischief` 的 7 个字段一一对应；`StringName` 在线上转成 `String`。
  客户端用这 7 个字段本地重建 `Mischief` 对象。
- **Session 的连接超时兜底只对客户端生效**：房主永远不会收到 `server_connected`（该信号是 client 专用），
  房主若也起超时计时器会在建房若干秒后**把自己刚建的房间拆掉**。
- **名单广播不能放在原生 peer 信号回调里同步发**：原生 `peer_connected` 早于 MultiplayerAPI 的名单刷新，
  此时 `rpc_id` 会被引擎拒绝（`Attempt to call RPC with unknown peer ID`）。
  → 广播必须推迟（`call_deferred`）或改走 MultiplayerAPI 层的 peer 事件。
- **真实联机链必须有自动化覆盖**：headless 单进程里两个 peer 无法共用同一个 `MultiplayerAPI`，
  用测试自己伪造的"投递层"会掩盖真实缺陷（Task 7 审查已实证）。
  → P1 必须有**双进程真实 RPC 测试**（同一条 `tools/test_*.gd` 内用 `OS.execute` 拉起两个真 Godot 进程，
  走真实的 `rpc_id` 投递），否则 Task 13 手动验收会反复踩同一批坑。
- **「零引擎 ERROR / WARNING」这类断言必须配反向自检**（故意造一条噪声 → 断言确实判失败），
  否则它可能因子进程压掉日志而**恒真**，覆盖声明就不成立（Task 7 修复轮 2 的 N-A 就是这么发生的）。
  扫噪声用 `contains("ERROR:")` / `contains("WARNING:")` / `contains("SCRIPT ERROR")`
  （`push_error` / `push_warning` 的输出行首带冒号）。

### 下列裁决由 Task 8–12 的控制器实测得出，**计划正文里对应的写法是错的，照抄会红**

> 每条都标注了「计划正文在哪」。这是给后续实现者的**陷阱清单**。

**Godot 4.7.2 的引擎事实**

- **`.tscn` 里的 `[sub_resource]` 必须写在 `[node]` 之前**（计划 Task 8 的 `player.tscn` 写在场景末尾）。
  写错的后果是**整个场景解析失败**（`Parse Error: Invalid parameter`），`load()` 返回 `null`。
- **`SceneReplicationConfig` 的属性键是 `NodePath(".:position")`**，不是 `^"position"`
  （计划 Task 8 的测试写 `has_property(^"position")` → **恒为 false**）。
  `property_get_spawn()` 对**不存在的路径**会打引擎 ERROR（`scene_replication_config.cpp:169`）；
  `has_property()` 不会（可安全用于反向自检）。
- **`replication_mode`：1 = `ALWAYS`，2 = `ON_CHANGE`**（计划 Task 8 写 `1` 并注释成 `ON_CHANGE` —— 注释是错的）。
  断言时用**常量** `SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE`，不要写死数字。
- **纯数字的节点名可用**：`name = "1075349658"` → 路径 `/root/1075349658`，
  `get_node_or_null("1075349658")` 命中 → 「节点名 = peer id = 权威」的方案成立。
- **`MultiplayerSpawner.spawn_function` 会被调用，返回节点的自定义名字被保留**
  （`spawn(733754800)` → `/root/Host/Players/733754800`）→ 玩家生成可以用它统一命名。
  ⚠ GDScript 的 lambda **按值捕获**，探针里想在 lambda 内观察外部变量会看到旧值。
- **`Dictionary` 的 String 与 StringName 键可互查**（`d.has("carrot")` 对 `&"carrot"` 键为 true）。
- **`JSON.parse_string()` 把 `[30,18]` 解析成 `[30.0, 18.0]`（float）** → 转换要显式 `int()` / `float()`。
- **`--script` 模式下 autoload 实例存在于场景树**（`/root/Session` 可取到），
  但**编译期**的全局标识符 `Session` 不能当表达式用 → 类型标注与 `Session.new()` 都会编译失败。

**Task 8（玩家与地图）**

- `data/map.json` 的道具 tag 必须覆盖 `data/mischief.json` 里**全部** `target_tag`
  （9 个：carrot/hat/basket/chair/barrel/lamp/bench/pot/sign）→ 否则 Task 10 会出现「目标不存在」。
- `scripts/game/world_map.gd` 是**纯逻辑层**：不许 `get_tree()` / `get_node()`；`FileAccess` / `JSON` 允许。
- 贴图索引用 `posmod(player_index, 6)`（`%` 对负数返回负数）。

**Task 9（守卫与押送）**

- **`begin_carry()` 无参**（计划 Produces 写 `begin_carry(peer_id)`、参考实现写 `begin_carry()`、测试调无参 —— 三者不自洽）。
- **CARRY / RETURN 的早退分支必须插在 `update()` 的 ctx 解析之后**（`visible` / `noise_active` 是局部变量，
  插在开头会 `Compile Error`）。
- **CHASE 必须有回落路径**（计划正文没写）→ 跟丢（不可见且 suspicion 归零）→ 离开 CHASE。
- **「送回出生点」必须真的实现**（计划正文只有一个信号，没有实现代码）。
  ⚠ **权威冲突**：玩家位置是**拥有者权威** → **房主不许直接写远端玩家的 `position`**
  → 必须是**被抓玩家自己**朝自己的出生点移动。出生点**每人一个**（镇口两侧）。
- **`light_factor` 不许写死 1.0**（计划正文 `var light := 1.0`）→ 「拔路灯让守卫视野 -40%」这条核心玩法才生效。
  规则：守卫 5 格（160 px）内每有一盏**熄灭**的路灯 → `light_factor *= 0.6`。
- **`scripts/net/game_rpc.gd` 由 Task 9 创建**（计划里 Task 11 引用了它，却没有任何任务创建 → 计划有洞）；
  Task 10 在同一文件追加 `submit_mischief` / `resolve_mischief`。
- **★ Task 9 已落地并锁定（commit `c74dcf2`，Task 10/11 必须逐字对齐）**：
  - `GuardBrain.begin_carry()` **无参**、`finish_carry()`、
    `static func compute_light_factor(guard_pos: Vector2, lamps: Array, radius: float) -> float`
    （灯的字典形状 `{"position": Vector2, "on": bool}`）。
  - `scripts/guard.gd` 的依赖**全部靠注入**：`set_player_root()` / `set_lamp_root()` /
    `set_lamps()` / `set_rpc()` —— **不硬编码场景路径**。
  - `@export var guard_id: StringName`（数据 id）与 `@export var guard_wire_id: int`（**网络寻址编号**）
    是**两个东西**；RPC 线上传的是 `guard_wire_id`。
  - **★ 灯的亮灭契约**：优先级 = **meta `"lamp_on"` → 属性 `lamp_on` → 都没有就当亮着**。
    Task 10 负责真正把灯弄灭，**必须走这个契约**，不许自创读取方式。
  - **`guard_state` 的广播绝不能回写 `brain.state`**（实现者踩过：房主自己的广播用陈旧的 `st` 覆盖状态机）。
  - **实测引擎语义**：`call_local` 的 `.rpc()` **本地也执行**、`call_remote` 本地不执行
    → **房主自己被抓时必须本地投递**，否则押送卡死。
  - `player.gd`：`var spawn_position` + `set_spawn_position()`（**Task 11 分配「每人固定位置」**）、
    `var escorted`（被押送中）、`const ESCORT_ARRIVE_TOLERANCE := 8.0`、
    `signal escort_finished(peer_id)`、`set_rpc()`（不硬编码路径）。
  - 三个 RPC 签名与设计 §5.3 **逐字一致**：`player_caught(peer_id, guard_id)` /
    `guard_state(guard_id, state, position, target_peer)` / `escort_finished(peer_id)`。
    **Task 10 只许追加 `submit_mischief` / `resolve_mischief`，不许动这三个。**


**Task 10（捣蛋交互与裁决）**

- **`behavior_id` 必须真的进广播载荷**（计划写的是空串）→ 载荷固定 4 字段
  `{peer_id, behavior_id, success, reason}`。
- **`has_partner` / `needs_partner` 不许硬编码** → `needs_partner` 取自 `Mischief.needs_partner`；
  `has_partner` 取自实际搭档状态。**缺搭档时所需时间是 2 倍**（效率减半）。
- **`target_id` 的「先到先得」台账在房主侧**（`Rules` 是无状态单次裁决，不裁决归属）；
  落败方**不扣分、不淘汰**（零失败惩罚）。
- **`caught` 用 `reason` 表达**，不额外进载荷（`reason == "caught"` ⇔ `caught`）。
- **两个抓捕通道必须分开**：守卫通道（Task 9，任意时刻可触发）vs 裁决通道（Task 10，只在完成瞬间）。
  `Rules.evaluate()` **只在完成瞬间**调用；`reason == "in_progress"` 是**非终态**。
- `Interaction.find_prop_in_range` **可以**拿 Node2D 参数、**可以**读 `global_position`
  （Pre-flight 裁定），但**不许**调 `get_tree()` / `get_node()`，且必须对**脱离场景树**的节点可用。
- **★ 进度必须两个字段**（控制器裁定，Task 9 复审后明确）：
  **① 已完成的捣蛋次数**（结算进度）**不清零**；
  **② 当前那一条的「进行中」进度**作废（不是惩罚，那一条要重做）。
  → **必须分属不同字段**，**不许用同一个 `progress` 字段**表达两件事。
  → Task 9 的 `test_guard_flow.gd` 有一条「押送期间玩家脚本变量除 `escored`/`_bob` 外零变化」的断言
  → 新增进度字段后**只**把「进行中进度」加进那条排除名单，**「已完成的捣蛋次数」必须留在受检集合内**。
- **★ 拔路灯的「实际熄灯」归 Task 10**，且必须走 Task 9 已定的读取契约：
  **meta `"lamp_on"` → 属性 `lamp_on` → 都没有就当亮着**。
  **同一盏灯只能选一种注入方式**（`set_lamps()` 数组 **或** `lamp_root` 子节点）——
  两种都上会被算两次 → `light_factor` 变成 0.36 而不是 0.6。
  → `scripts/guard.gd` **不许改**（只能通过它定义的契约影响它）。
- **★ `game_rpc.gd` 的追加禁改清单**（Task 9 复审实测得出）：
  不许动 `player_caught` / `guard_state` / `escort_finished` 三个方法及其 `@rpc` 修饰符、
  `HOST_PEER_ID` 常量、`send_escort_finished` 的**房主本地投递分支**
  （实测 `call_remote` 本地**不执行** → 房主自己被抓时押送会卡死）、
  三个信号名 `caught_player_evt` / `guard_state_evt` / `escort_completed_evt`。
  → 新增方法的 `@rpc` 传输模式**要有断言钉住**（否则下一个人改错了没人知道）。
- **★ `guard_wire_id` 的分配规则**：线上只有 int，客户端**没法**从 int 反查数据 id
  → 编号必须**唯一**，且与 `data/guards.json` 的顺序**确定性绑定**，**不许依赖默认值 1**。
- **★ peer id 解析不许再添第三套**：一律走 `Player.resolve_authority()`
  （严格规则 `^[1-9][0-9]{0,9}$` 且 ∈ [1, 2^31-1]，否则兜底 1）。
  `scripts/guard.gd` 现在用的是宽松的 `is_valid_int()`（`"007"`→7）→ 两套不一致，留给最终审查。


**Task 11（镇子场景与 HUD）**

- **玩家生成必须统一用 `MultiplayerSpawner`**（计划正文两套机制打架）：
  设 `spawn_function` 命名 + 房主 `spawner.spawn(peer_id)`；
  **禁止** `players_root.add_child(p)`（手搓的节点在客户端根本不存在）。
- **`player_index` 必须是稳定的 0–5 序号**，不能是 `peer_id - 1`（客户端 peer id 是随机 32 位数）。
- **HUD 显示的是自己那一份清单** —— 房主侧 `Session.deal()` 返回**全员**手牌，不许直接拿来显示。

**Task 12（回合流程与端到端冒烟）**

- **`--script` 模式的测试里不能用 `Session` 当类型标注，也不能 `Session.new()`** → 用不带标注的
  `get_node_or_null("Session")` 与 `preload("res://scripts/net/session.gd").new()`。
  （场景脚本里 `var _session: Session = null` 是**正常项目模式**，照抄没问题。）
- **`resolve_mischief` 是 4 个参数**（计划冒烟测试调了 3 个）→ `resolve_mischief(1, &"steal_carrot", true, "ok")`。
- 冒烟测试的端口**不要用 27017**（与 Task 6 的 27015–27024 撞车）→ 用 27050。
- **`round_started` / `round_ended` 的广播 Task 7 已经做了** → Task 12 核实即可，不要重复实现。

**全局（Task 9–13 全部继承）：测试端口必须动态分配，不许再硬编码任何 270xx**

> 来源：Task 7 修复轮 3（2026-11-04）。计划正文的 `test_transport.gd` / `test_session.gd` /
> `test_session_link.gd` 都写死了端口号，Task 12 的冒烟测试也写死了 27050 ——
> **全部都要改成动态分配**。

- **为什么**：SDD 流程里「控制器跑统一入口」与「复审子代理跑测试」**必然并发**。
  固定端口 → 必然产生**假失败**（不是代码缺陷）。
  已实测两次：占住 UDP 27040 → `test_session_link.gd` **12 条断言连锁失败**、退出码 1，
  端口释放后立刻恢复全绿；Task 8 复审者首跑统一入口独立撞上 **7/9**。
- **★ 核心裁决：禁止「探测 → 关闭 → 盲信」**（探测 socket bind 一下就 close，然后把端口号交出去）。
  端口的裁决权归**真实的服务端 socket**：`host()` / `create_server()` **绑定成功**才算可用，
  **绑定失败就换下一个候选**继续试。
  理由：探测与真实绑定之间存在竞态窗口，两个并发进程可能同时探测到同一端口 →
  只是把「固定端口冲突」换成「概率性冲突」。
  （前提已验证：本机 UDP 端口**独占绑定** —— 已有断言「另一个 transport 在同一端口上 host 必须失败」。）
- **候选池**：`27100` 起、跨 `200` 个（27100–27299）；必须避开 27015–27024（Task 6）、
  27030–27034（Task 7 单进程）、27040 / 27041（Task 7 双进程）、27050（Task 12）。
  候选用尽 → **明确失败**，**严禁**静默回退到任何固定端口。
- **工具类 `tools/port_alloc.gd` 不写 `class_name`** → 调用方用
  `const PortAlloc := preload("res://tools/port_alloc.gd")`
  （沿用 Task 7「`class_name` 与同名 autoload 互斥」的教训）。
- **双进程 link 测试需要「交接文件」**：房主在子进程里，父进程必须在启动客户端**之前**知道
  房主实际占的端口 → 房主子进程绑定成功后把端口号写进交接文件，父进程**轮询**该文件
  （替代计划里 `OS.delay_msec(1500)` 那种魔法延迟），拿到端口再启动客户端。
  交接文件路径必须**每次唯一**（并发跑时互不干扰）。
- **Task 9–13 的所有新测试必须用动态端口**，新端口只能从 27100+ 段里取。

**Task 10 交付的契约（Task 11 / 12 必须逐字对齐）**

> 来源：Task 10 实现 commit `f928226` + 修复轮 1 commit `dbe8a4e`（2026-11-04）。
> 计划正文 Task 10 的 `game_rpc.gd` 参考实现有 5 处错，见下面每条。

- **`behavior_id` 必须真的进广播载荷，且载荷恰好 4 个字段**
  （计划正文写 `mischief_resolved.emit(peer_id, &"", …)` → `behavior_id` 是**空串**）。
  → 载荷 = `{peer_id: int, behavior_id: StringName, success: bool, reason: String}`；
  `caught` **不单独进载荷**（用 `reason == "caught"` 表达）。
  → **线上 `behavior_id` 是 `String`**（StringName 线上要转 String，Task 7 的教训），
    **信号层**再转回 `StringName`。
- **`has_partner` / `needs_partner` 不许硬编码**（计划正文写死 true/false → 搭档机制完全没接线）。
  → `needs_partner` 取自那张牌自己的 `Mischief.needs_partner`；
    `has_partner` 取自实际搭档状态（`Interaction.has_partner_near()`）。
  → 效率倍率 = 需要搭档且缺搭档时 **duration × 2**（纯函数 `Interaction.effective_duration()`）。
- **「先到先得」台账在**房主侧**（计划正文让 `Rules` 裁决归属 → 但 `Rules` 是无状态单次裁决，
  明写「本层不裁决归属」）。→ `Interaction.ClaimLedger`（纯逻辑、可单测）。
  落败方**零惩罚**：只是这一条行为算没完成。
- **两个抓捕通道必须分开**：
  - 守卫通道（Task 9）：`GuardBrain.update()` 返回 `catch_player` → **任意时刻**可触发 → 押送；
  - 裁决通道（Task 10）：`Rules.evaluate()` 的 `reason == "caught"` → **只在捣蛋完成瞬间**被问询。
  → `Rules.evaluate()` **只在完成瞬间**调用（`progress >= 1.0`）；
    `reason == "in_progress"` 是**非终态** → 不广播 / 不清进度 / 不触发护送 / 不占台账。
- **进度必须两个字段**（P1「进度不清零」与设计 §4.3「失去手中未交付的道具」是两件事）：
  - `completed_mischief: int` —— 已完成捣蛋次数，**被抓 / 落败都不清零**（零失败惩罚）；
  - `current_mischief_progress: float` —— 手上那一条的进行中进度，**被抓时作废**（那一条要重做，
    **不是惩罚**）。
  → **不许**用一个字段表达这两件事。
- **拔路灯的实际熄灯**只走 Task 9 已定的读取契约：
  **meta `"lamp_on"` → 属性 `lamp_on` → 都没有就当亮着**（`guard.gd:_lamp_is_on()`）。
  → 熄灯**只写 meta `"lamp_on"`**（`Interaction.set_lamp_on()`）。
  → **同一盏灯只能选一种注入方式**（`set_lamp_root()` **或** `set_lamps()`，不许同时）
    —— 两种都上 → 同一盏灯算两遍 → `light_factor` = 0.6 × 0.6 = **0.36**（而不是 0.6）。
- **★ 断言不许依赖工作区的换行符**（Task 10 修复轮 1 的实测教训）：
  仓库已加 `.gitattributes`（`* text=auto eol=lf`），但**断言自身仍必须先归一化换行**再比对
  —— 否则「同一个 commit 在干净检出上跑不过自己的测试」（实测：5 条 §4-17 全红、退出码 1）。
  → 写「逐字比对源码文本」的断言时，一律先 `replace("\r\n","\n")`。
- **★ 生产入口函数必须被真正执行过**：只测内部函数 + 文本扫描是不够的
  —— `submit_mischief()` / `send_submit_mischief()` 两个 RPC 入口曾**从未被测试调用过**，
  三个变异（progress 改 0.5 / 删掉房主本地投递分支 / 房主写远端玩家进度）**全部漏网**。
  → `@rpc("call_remote")` **只影响 `.rpc()` 调用**；**直接调方法体会照常执行** —— 这就是补行为断言的手法。






## 规格来源

完整设计见 `docs/superpowers/specs/2026-11-03-after-hours-design.md`。本计划只覆盖其中的 **Phase 1**；P2（Steam）、P3（内容与美术）、P4（AI NPC）、P5（上架）各自另写计划。

---

## 文件结构（Phase 1 锁定）

```
after-hours/
├── project.godot
├── icon.svg
├── scenes/
│   ├── main.tscn              # 启动场景（极薄），路由交给 autoload Router
│   ├── lobby.tscn             # 大厅
│   ├── game.tscn              # 镇子场景
│   ├── player.tscn
│   ├── guard.tscn
│   └── ui/hud.tscn
├── scripts/
│   ├── net/
│   │   ├── transport.gd       # Transport 抽象基类
│   │   ├── enet_transport.gd  # P1 唯一实现
│   │   └── session.gd         # Node：大厅/成员/回合
│   ├── game/
│   │   ├── mischief.gd        # Mischief 数据类 + JSON 加载
│   │   ├── mischief_deck.gd   # 清单生成（纯函数）
│   │   ├── guard_brain.gd     # 守卫感知与状态机（纯逻辑）
│   │   └── rules.gd           # 捣蛋裁决（纯函数）
│   ├── player.gd              # Node 封装
│   ├── guard.gd               # Node 封装
│   └── ui/
│       ├── lobby_ui.gd
│       └── hud.gd
├── data/
│   ├── mischief.json          # 10 种行为（P1）
│   └── guards.json            # 1 个守卫 + 台词（P1）
├── tools/
│   ├── gen_placeholder_art.py # 占位素材生成
│   ├── test_mischief_deck.gd
│   ├── test_guard_brain.gd
│   ├── test_rules.gd
│   ├── test_transport.gd
│   └── test_smoke.gd
└── assets/
    ├── ground/  props/  chars/  ui/
```

**边界规则（每个任务都遵守）**

- `scripts/game/**` 只依赖纯数据，不依赖 `Node`
- `scripts/net/transport.gd` 定义接口，`enet_transport.gd` 是唯一实现；`session.gd` 只通过 `Transport` 接口说话
- `scripts/player.gd` / `guard.gd` 是场景节点的薄封装，业务判断一律委托给 `scripts/game/**` 的纯逻辑类

---

## Task 1: Godot 项目骨架与引擎配置

**Files:**
- Create: `project.godot`, `icon.svg`
- Create: `scenes/main.tscn`
- Create: `scripts/ui/router.gd`（注册为 autoload）
- Create: `tools/test_project.gd`

**Interfaces:**
- Consumes: 无
- Produces: 项目可被 Godot 打开；`Router` 节点提供 `goto(scene_path: String) -> void`

- [ ] **Step 1: 写失败的冒烟测试**

`tools/test_project.gd`：

```gdscript
extends SceneTree

## P1 冒烟测试：项目配置正确 + 能加载主场景 + 能跳转场景。

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	# 1) 工程配置
	var cfg := ConfigFile.new()
	var err := cfg.load("res://project.godot")
	fails += _check(err == OK, "project.godot 可加载")
	fails += _check(cfg.get_value("display", "window/size/viewport_width", 0) == 640, "逻辑宽度 640")
	fails += _check(cfg.get_value("display", "window/size/viewport_height", 0) == 360, "逻辑高度 360")
	fails += _check(cfg.get_value("rendering", "renderer/rendering_method", "") == "gl_compatibility", "gl_compatibility 后端")

	# 2) 主场景可实例化
	var packed: PackedScene = load("res://scenes/main.tscn")
	fails += _check(packed != null, "main.tscn 可加载")
	if packed != null:
		var scene := packed.instantiate()
		root.add_child(scene)
		await process_frame
		fails += _check(root.get_node_or_null("Router") != null, "Router 自动加载已注册")
		scene.queue_free()

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_project.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `project.godot` 不存在，`load()` 返回 null

- [ ] **Step 3: 建工程配置**

`project.godot`：

```ini
; Engine configuration file.
config_version=5

[application]
config/name="After Hours"
config/description="2-6 人派对捣蛋：镇长不在的时候"
config/version="0.1.0"
run/main_scene="res://scenes/main.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")
config/icon="res://icon.svg"
boot_splash/show_image=false
boot_splash/bg_color=Color(0.07, 0.08, 0.12, 1)

[autoload]

Router="*res://scripts/ui/router.gd"

[display]
window/size/viewport_width=640
window/size/viewport_height=360
window/size/window_width_override=1280
window/size/window_height_override=720
window/stretch/mode="canvas_items"
window/stretch/aspect="keep"

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
textures/canvas_textures/default_texture_filter=1
environment/defaults/default_clear_color=Color(0.07, 0.08, 0.12, 1)
```

> `default_texture_filter=1` 是 Linear。手绘风不用 Nearest。

`icon.svg`（128×128，深蓝底 + 一盏黄灯笼）：

```svg
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <rect width="128" height="128" fill="#131722"/>
  <rect x="46" y="20" width="36" height="8" fill="#6b5a2e"/>
  <rect x="50" y="28" width="28" height="52" rx="6" fill="#f5d67a" stroke="#8a6f2c" stroke-width="4"/>
  <rect x="46" y="80" width="36" height="8" fill="#6b5a2e"/>
  <circle cx="64" cy="52" r="9" fill="#fff3c4"/>
  <rect x="62" y="6" width="4" height="14" fill="#8a6f2c"/>
</svg>
```

`scenes/main.tscn`：

```
[gd_scene format=3]

[node name="Main" type="Node"]
```

`scripts/ui/router.gd`（**注册为自动加载**，所以切换场景后依然存活）：

```gdscript
extends Node

## 场景路由：大厅 / 游戏之间切换。作为 autoload 常驻。

func goto(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)


func _ready() -> void:
	call_deferred("_boot")


func _boot() -> void:
	await get_tree().process_frame
	# headless 测试用 `--script` 启动时没有主场景，此时不要自动跳转，
	# 否则会在测试跑到一半时把场景换掉。
	if get_tree().current_scene == null:
		return
	goto("res://scenes/lobby.tscn")
```

> **Router 必须做成 autoload**：大厅和游戏之间用 `change_scene_to_file` 切换会释放当前场景，
> 如果 Router 在场景里，它自己会先被释放掉，就没法再跳转了。

- [ ] **Step 4: 跑测试确认通过**

Run: --import （首次必须先导入资源）
Run: `godot --headless --path . --quit-after 600 --script res://tools/test_project.gd   # 前置：先跑一次 --import`
Expected: PASS，`TEST PASSED`，退出码 0

> Router 是 autoload，`--script` 模式下 `get_tree().current_scene` 为 null，
> 所以它不会在测试中途切场景。如果 `goto` 报 "Can't change scene"，
> 把 `router.gd` 里的跳转改成 `call_deferred("goto", "res://scenes/lobby.tscn")`。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: Godot 项目骨架与引擎配置"
```

---

## Task 2: 占位美术素材管线

**Files:**
- Create: `tools/gen_placeholder_art.py`
- Create: `assets/ground/ground_grass.png`, `assets/ground/ground_path.png`
- Create: `assets/chars/char_0.png` … `char_5.png`
- Create: `assets/props/prop_*.png`
- Test: `tools/test_art.gd`

**Interfaces:**
- Consumes: 无
- Produces: 素材文件路径约定——地面 `assets/ground/{ground_grass,ground_path}.png`；角色 `assets/chars/char_{0..5}.png`（各 64×64，**单张立绘，不是序列帧**）；道具 `assets/props/prop_{id}.png`（各 32×32）

- [ ] **Step 1: 写失败的测试**

`tools/test_art.gd`：

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0
	for i in 6:
		var p := "res://assets/chars/char_%d.png" % i
		fails += _check(FileAccess.file_exists(p), "存在 %s" % p)
		if FileAccess.file_exists(p):
			var tex: Texture2D = load(p)
			fails += _check(tex != null and tex.get_width() == 64 and tex.get_height() == 64,
				"char_%d.png 是 64x64" % i)
	for n in ["ground_grass", "ground_path"]:
		var p2 := "res://assets/ground/%s.png" % n
		fails += _check(FileAccess.file_exists(p2), "存在 %s" % p2)
	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_art.gd   # 前置：先跑一次 --import`
Expected: FAIL —— 素材文件不存在

- [ ] **Step 3: 写生成器**

`tools/gen_placeholder_art.py`（Pillow，固定种子，输出可重复）：

```python
# -*- coding: utf-8 -*-
"""占位素材生成器（P1 用；P3 会被 AI 手绘素材替换）。

生成规则：
  地面   256x256 可平铺纹理
  角色   64x64 单张立绘（脚底对齐原点，程序化动画用）
  道具   32x32 单物件
"""
import math
import os
import random

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
random.seed(20261103)

PALETTE = [
    ((214, 122, 96), (168, 88, 70), (96, 56, 44)),    # 0 红
    ((118, 168, 214), (86, 128, 170), (56, 84, 118)),  # 1 蓝
    ((140, 190, 120), (106, 150, 92), (68, 102, 62)),   # 2 绿
    ((226, 196, 118), (186, 156, 88), (124, 100, 58)), # 3 黄
    ((178, 142, 200), (138, 108, 160), (94, 72, 112)), # 4 紫
    ((240, 178, 140), (196, 142, 110), (136, 96, 72)),  # 5 肤/棕
]
NIGHT = (38, 44, 62)
NIGHT_L = (52, 60, 82)
GRASS = (74, 106, 74)
GRASS_L = (88, 122, 86)
DIRT = (120, 96, 70)
DIRT_L = (142, 116, 86)


def ensure(path):
    os.makedirs(path, exist_ok=True)
    return path


def ground_tiles(name, base, light):
    im = Image.new("RGB", (256, 256), base)
    d = ImageDraw.Draw(im)
    for _ in range(900):
        x, y = random.randrange(256), random.randrange(256)
        d.point((x, y), fill=light)
    for _ in range(40):
        x, y = random.randrange(256), random.randrange(256)
        d.ellipse((x, y, x + 2, y + 1), fill=light)
    im.save(os.path.join(ensure(os.path.join(ROOT, "assets", "ground")), name + ".png"))


def character(idx):
    main, dark, line = PALETTE[idx % len(PALETTE)]
    im = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    # 影子
    d.ellipse((20, 54, 44, 60), fill=(0, 0, 0, 60))
    # 身体
    d.rounded_rectangle((22, 26, 42, 54), radius=6, fill=main, outline=dark, width=2)
    # 头
    d.ellipse((22, 8, 42, 30), fill=(246, 212, 178), outline=dark, width=2)
    # 头发/帽子
    d.pieslice((21, 4, 43, 26), 180, 360, fill=dark)
    # 眼睛
    d.rectangle((28, 17, 30, 20), fill=(30, 26, 24))
    d.rectangle((35, 17, 37, 20), fill=(30, 26, 24))
    # 手臂
    d.line((22, 32, 16, 46), fill=main, width=5)
    d.line((42, 32, 48, 46), fill=main, width=5)
    im.save(os.path.join(ensure(os.path.join(ROOT, "assets", "chars")),
                         "char_%d.png" % idx))


def prop(name, color):
    im = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.ellipse((6, 8, 26, 28), fill=color, outline=(40, 34, 30), width=2)
    d.ellipse((10, 11, 18, 17), fill=(255, 255, 255, 60))
    im.save(os.path.join(ensure(os.path.join(ROOT, "assets", "props")), name + ".png"))


ground_tiles("ground_grass", NIGHT, NIGHT_L)
ground_tiles("ground_path", DIRT, DIRT_L)
for i in range(6):
    character(i)
for name, col in [
    ("prop_carrot", (226, 118, 58)),
    ("prop_chair", (150, 110, 66)),
    ("prop_barrel", (158, 112, 64)),
    ("prop_lamp", (250, 226, 140)),
    ("prop_sign", (186, 158, 110)),
    ("prop_pot", (176, 104, 70)),
    ("prop_bench", (140, 104, 62)),
    ("prop_basket", (198, 168, 110)),
    ("prop_dog", (168, 132, 92)),
    ("prop_hat", (72, 62, 96)),
]:
    prop(name, col)
print("placeholder art written to", ROOT)
```

- [ ] **Step 4: 生成并跑测试**

```bash
python tools/gen_placeholder_art.py
godot --headless --path . --import
godot --headless --path . --quit-after 600 --script res://tools/test_art.gd   # 前置：先跑一次 --import
```
Expected: PASS，退出码 0

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 占位美术素材管线（Pillow 程序化生成）"
```

---

## Task 3: 捣蛋行为数据模型与清单生成

**Files:**
- Create: `scripts/game/mischief.gd`, `scripts/game/mischief_deck.gd`
- Create: `data/mischief.json`
- Test: `tools/test_mischief_deck.gd`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class_name Mischief extends Resource`，字段 `id: StringName`、`title: String`、`category: StringName`、`target_tag: StringName`、`needs_partner: bool`、`duration: float`、`points: int`
  - `Mischief.load_all(path: String = "res://data/mischief.json") -> Array[Mischief]`
  - `class_name MischiefDeck extends RefCounted`
  - `MischiefDeck.generate(all: Array[Mischief], player_count: int, rng: RandomNumberGenerator, available_tags: Array[StringName]) -> Array[Array]` —— 返回每人一张牌数组，长度 = player_count。
    返回类型只能是 `Array[Array]`：Godot 4.7.2 不支持嵌套带类型数组（`Array[Array[Mischief]]` 解析期直接报错）。

**生成规则（必须逐条实现并被测试覆盖）**
1. 每人的牌数 `N = clamp(player_count + 1, 3, 5)`
2. 池子里只保留 `target_tag` 出现在 `available_tags` 中的行为
3. 同类（category）在**每份清单内**不超过 2（作用域 = 每份清单各自成立，见下方裁决）
4. **每份清单**至少有 1 张 `noise` 或 `decor`
5. **每份清单**至少有 1 张 `prank`
6. 每人拿到不同的子集 —— **按集合口径判定**（两份清单包含的行为集合不得相同，顺序无关）；
   允许跨玩家持有同一张牌（4-6 人局不可避免，见下方裁决）

- [ ] **Step 1: 写失败的测试**

`tools/test_mischief_deck.gd`：

```gdscript
extends SceneTree

## 清单生成规则的单元测试。全部是纯逻辑，不需要场景树。

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0
	var all := Mischief.load_all()
	fails += _check(all.size() == 10, "P1 有 10 种行为，实际 %d" % all.size())

	# 每种行为字段完整
	for m in all:
		fails += _check(m.id != "" and m.title != "" and m.category != "" and m.target_tag != "",
			"行为 %s 字段完整" % m.id)

	var tags: Array[StringName] = []
	for m in all:
		tags.append(m.target_tag)

	for pc in [2, 3, 4, 6]:
		var rng := RandomNumberGenerator.new()
		rng.seed = 12345 + pc
		var deal := MischiefDeck.generate(all, pc, rng, tags)
		fails += _check(deal.size() == pc, "%d 人局分 %d 份" % [pc, deal.size()])

		var expect_n: int = clampi(pc + 1, 3, 5)
		for p in deal:
			fails += _check(p.size() == expect_n, "%d 人局每人 %d 张（实际 %d）" % [pc, expect_n, p.size()])

		# 规则 3：同类不超过 2
		var cats := {}
		for m in deal[0]:
			cats[m.category] = int(cats.get(m.category, 0)) + 1
		var over := false
		for c in cats:
			if int(cats[c]) > 2:
				over = true
		fails += _check(not over, "%d 人局同类不超过 2 张" % pc)

		# 规则 4/5
		var has_noise_or_decor := false
		var has_prank := false
		for m in deal[0]:
			if m.category == "noise" or m.category == "decor":
				has_noise_or_decor = true
			if m.category == "prank":
				has_prank = true
		fails += _check(has_noise_or_decor, "%d 人局至少有 1 张 noise/decor" % pc)
		fails += _check(has_prank, "%d 人局至少有 1 张 prank" % pc)

		# 规则 6：两人局两人拿到的是不同子集
		if pc >= 2:
			var a := _ids(deal[0])
			var b := _ids(deal[1])
			fails += _check(a != b, "%d 人局不同玩家牌组不同" % pc)

	# 目标不在地图上的行为应被过滤
	var only_carrot: Array[StringName] = [&"carrot"]
	var rng2 := RandomNumberGenerator.new()
	rng2.seed = 999
	var deal2 := MischiefDeck.generate(all, 2, rng2, only_carrot)
	var all_carrot := true
	for m in deal2[0]:
		if m.target_tag != &"carrot":
			all_carrot = false
	fails += _check(all_carrot, "只发目标存在的牌")

	# 确定性：同种子同结果
	var r1 := RandomNumberGenerator.new()
	r1.seed = 777
	var r2 := RandomNumberGenerator.new()
	r2.seed = 777
	fails += _check(_ids(MischiefDeck.generate(all, 3, r1, tags)[0]) ==
		_ids(MischiefDeck.generate(all, 3, r2, tags)[0]), "同种子结果一致")

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _ids(list: Array) -> Array:
	var out := []
	for m in list:
		out.append(String(m.id))
	return out


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_mischief_deck.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `Mischief` 类不存在

- [ ] **Step 3: 写数据与实现**

`data/mischief.json`（10 种，覆盖 5 类）：

```json
[
  {"id":"steal_carrot","title":"偷走杂货铺的萝卜","category":"steal","target_tag":"carrot","needs_partner":false,"duration":1.5,"points":10},
  {"id":"steal_hat","title":"偷走镇长的帽子","category":"steal","target_tag":"hat","needs_partner":false,"duration":1.5,"points":10},
  {"id":"steal_basket","title":"偷走酒馆的篮子","category":"steal","target_tag":"basket","needs_partner":false,"duration":1.5,"points":10},
  {"id":"mess_chairs","title":"把广场椅子堆成塔","category":"mess","target_tag":"chair","needs_partner":true,"duration":3.0,"points":15},
  {"id":"mess_barrel","title":"打翻广场的木桶","category":"mess","target_tag":"barrel","needs_partner":false,"duration":1.0,"points":10},
  {"id":"mess_lamps","title":"拔掉街上的路灯","category":"mess","target_tag":"lamp","needs_partner":false,"duration":2.0,"points":15},
  {"id":"prank_bench","title":"把长椅搬到池塘边看日落","category":"prank","target_tag":"bench","needs_partner":true,"duration":3.0,"points":15},
  {"id":"prank_pot","title":"给花盆穿上外套","category":"prank","target_tag":"pot","needs_partner":false,"duration":2.0,"points":10},
  {"id":"decor_sign","title":"把告示牌倒过来","category":"decor","target_tag":"sign","needs_partner":false,"duration":1.0,"points":10},
  {"id":"noise_pot","title":"敲响酒馆的锅","category":"noise","target_tag":"pot","needs_partner":false,"duration":0.5,"points":15}
]
```

`scripts/game/mischief.gd`：

```gdscript
class_name Mischief
extends Resource

## 一种捣蛋行为的定义。纯数据，不依赖场景树。

@export var id: StringName = &""
@export var title: String = ""
@export var category: StringName = &""
@export var target_tag: StringName = &""
@export var needs_partner: bool = false
@export var duration: float = 1.0
@export var points: int = 10


static func load_all(path: String = "res://data/mischief.json") -> Array[Mischief]:
	var out: Array[Mischief] = []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("打不开捣蛋数据: " + path)
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_ARRAY:
		push_error("捣蛋数据不是数组: " + path)
		return out
	for entry in parsed:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var m := Mischief.new()
		m.id = StringName(str(entry.get("id", "")))
		m.title = str(entry.get("title", ""))
		m.category = StringName(str(entry.get("category", "")))
		m.target_tag = StringName(str(entry.get("target_tag", "")))
		m.needs_partner = bool(entry.get("needs_partner", false))
		m.duration = float(entry.get("duration", 1.0))
		m.points = int(entry.get("points", 10))
		out.append(m)
	return out


static func find_by_id(all: Array[Mischief], id: StringName) -> Mischief:
	for m in all:
		if m.id == id:
			return m
	return null
```

`scripts/game/mischief_deck.gd`：

```gdscript
class_name MischiefDeck
extends RefCounted

## 捣蛋清单生成。纯函数：同样的输入永远得到同样的输出。

const CATEGORIES := [&"steal", &"mess", &"prank", &"decor", &"noise"]
const MAX_PER_CATEGORY := 2


## 返回每人一张牌数组，长度 = player_count。
static func generate(all: Array[Mischief], player_count: int,
		rng: RandomNumberGenerator, available_tags: Array[StringName]) -> Array[Array]:
	var deal: Array[Array] = []
	for i in player_count:
		deal.append([] as Array[Mischief])
	if player_count <= 0 or all.is_empty():
		return deal

	var n: int = clampi(player_count + 1, 3, 5)

	# 规则 2：目标必须存在于本局地图
	var pool: Array[Mischief] = []
	for m in all:
		if available_tags.has(m.target_tag):
			pool.append(m)

	# 规则 3：同类不超过 2
	var per_cat := {}
	var picked: Array[Mischief] = []
	for m in pool:
		var c: int = int(per_cat.get(m.category, 0))
		if c >= MAX_PER_CATEGORY:
			continue
		picked.append(m)
		per_cat[m.category] = c + 1

	# 规则 4/5：保底
	_ensure_category(picked, pool, [&"noise", &"decor"])
	_ensure_category(picked, pool, [&"prank"])

	# 打乱
	_shuffle(picked, rng)

	# 规则 6：轮流发牌
	for i in picked.size():
		deal[i % player_count].append(picked[i])

	return deal


static func _ensure_category(picked: Array[Mischief], pool: Array[Mischief], cats: Array[StringName]) -> void:
	for c in cats:
		var has := false
		for m in picked:
			if m.category == c:
				has = true
				break
		if has:
			continue
		for m in pool:
			if m.category == c:
				picked.append(m)
				return


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_mischief_deck.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 捣蛋行为数据模型与清单生成器"
```

---

## Task 4: 守卫感知与状态机（纯逻辑）

**Files:**
- Create: `scripts/game/guard_brain.gd`
- Create: `data/guards.json`
- Test: `tools/test_guard_brain.gd`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class_name GuardBrain extends RefCounted`
  - `enum State { PATROL, SUSPICIOUS, CHASE, CARRY, RETURN }`
  - `GuardBrain.in_sight_cone(origin: Vector2, facing: Vector2, target: Vector2, sight_range: float, angle_deg: float) -> bool`（静态）
  - `GuardBrain.effective_sight_range(base_range: float, light_factor: float) -> float`（静态，light_factor ∈ [0,1]，1 = 全亮）
  - `GuardBrain.hearing_reached(dist: float, hearing_range: float) -> bool`（静态）
  - `GuardBrain.update(delta: float, ctx: Dictionary) -> Dictionary` —— ctx 键：`guard_pos`、`guard_facing`、`player_pos`、`player_visible`、`noise_pos`、`noise_active`、`sight_range`、`sight_angle_deg`、`hearing_range`、`target_peer`；返回 `{ state, target_peer, suspicion, catch_player }`
  - `data/guards.json` 结构：`[{ "id","name","sight_range","sight_angle_deg","hearing_range","lines":{ "spotted":[], "caught":[], "missing":[] } }]`

- [ ] **Step 1: 写失败的测试**

`tools/test_guard_brain.gd`：

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	# --- 视野锥形 ---
	var o := Vector2.ZERO
	var facing := Vector2.RIGHT
	fails += _check(GuardBrain.in_sight_cone(o, facing, Vector2(50, 0), 100, 80), "正前方可见")
	fails += _check(not GuardBrain.in_sight_cone(o, facing, Vector2(-50, 0), 100, 80), "正后方不可见")
	fails += _check(not GuardBrain.in_sight_cone(o, facing, Vector2(150, 0), 100, 80), "超出距离不可见")
	fails += _check(GuardBrain.in_sight_cone(o, facing, Vector2(30, 28), 100, 80), "锥形边缘内可见")
	fails += _check(not GuardBrain.in_sight_cone(o, facing, Vector2(30, 40), 100, 80), "锥形边缘外不可见")

	# --- 光照衰减 ---
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(100, 1.0), 100), "全亮时视野不变")
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(100, 0.6), 60), "光照 0.6 时视野 60%")
	fails += _check(is_equal_approx(GuardBrain.effective_sight_range(100, 0.0), 0.0), "全黑时视野为 0")

	# --- 听觉 ---
	fails += _check(GuardBrain.hearing_reached(50, 100), "在听觉范围内")
	fails += _check(not GuardBrain.hearing_reached(150, 100), "超出听觉范围")

	# --- 状态迁移：巡逻 -> 追击 ---
	var b := GuardBrain.new()
	var ctx := {
		"guard_pos": Vector2.ZERO, "guard_facing": Vector2.RIGHT,
		"player_pos": Vector2(50, 0), "player_visible": true, "noise_pos": Vector2.ZERO,
		"noise_active": false, "sight_range": 100.0, "sight_angle_deg": 80.0,
		"hearing_range": 0.0, "target_peer": 7,
	}
	var r1: Dictionary = b.update(0.1, ctx)
	fails += _check(int(r1["state"]) == GuardBrain.State.CHASE, "看到玩家进入 CHASE")
	fails += _check(int(r1["target_peer"]) == 7, "锁定目标 peer")
	fails += _check(bool(r1["catch_player"]), "距离够近时判定抓获")

	# --- 听觉引起怀疑 ---
	var b2 := GuardBrain.new()
	var ctx2 := ctx.duplicate()
	ctx2["player_visible"] = false
	ctx2["player_pos"] = Vector2(9999, 9999)
	ctx2["noise_active"] = true
	ctx2["noise_pos"] = Vector2(30, 0)
	ctx2["hearing_range"] = 100.0
	ctx2["sight_range"] = 10.0
	var r2: Dictionary = b2.update(0.1, ctx2)
	fails += _check(int(r2["state"]) != GuardBrain.State.CHASE, "只听到声音不当成 CHASE")
	fails += _check(float(r2["suspicion"]) > 0.0, "听到声音提升怀疑度")

	# --- 看不见则怀疑度下降 ---
	var b3 := GuardBrain.new()
	b3.suspicion = 1.0
	var ctx3 := ctx.duplicate()
	ctx3["player_visible"] = false
	ctx3["noise_active"] = false
	var r3: Dictionary = b3.update(0.5, ctx3)
	fails += _check(float(r3["suspicion"]) < 1.0, "看不见时怀疑度下降")

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_guard_brain.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `GuardBrain` 类不存在

- [ ] **Step 3: 实现**

`scripts/game/guard_brain.gd`：

```gdscript
class_name GuardBrain
extends RefCounted

## 守卫的感知与状态机。纯逻辑：不引用任何场景树节点，
## 输入是"世界快照"字典，输出是"下一个状态"字典。

enum State { PATROL, SUSPICIOUS, CHASE, CARRY, RETURN }

const SUSPICION_GAIN := 2.0
const SUSPICION_DECAY := 1.0
const SUSPICION_THRESHOLD := 0.5
const CATCH_DISTANCE := 24.0
const SIGHT_ANGLE_DEFAULT := 80.0

var state: int = State.PATROL
var suspicion: float = 0.0
var target_peer: int = 0


static func in_sight_cone(origin: Vector2, facing: Vector2, target: Vector2,
		sight_range: float, angle_deg: float) -> bool:
	if sight_range <= 0.0:
		return false
	var to := target - origin
	var dist := to.length()
	if dist > sight_range:
		return false
	if dist <= 0.0001:
		return true
	var f := facing.normalized()
	if f == Vector2.ZERO:
		return false
	var cos_a := cos(deg_to_rad(angle_deg * 0.5))
	return f.dot(to.normalized()) >= cos_a


static func effective_sight_range(base_range: float, light_factor: float) -> float:
	return maxf(0.0, base_range * clampf(light_factor, 0.0, 1.0))


static func hearing_reached(dist: float, hearing_range: float) -> bool:
	return hearing_range > 0.0 and dist <= hearing_range


func update(delta: float, ctx: Dictionary) -> Dictionary:
	var player_pos: Vector2 = ctx.get("player_pos", Vector2.ZERO)
	var guard_pos: Vector2 = ctx.get("guard_pos", Vector2.ZERO)
	var facing: Vector2 = ctx.get("guard_facing", Vector2.RIGHT)
	var visible: bool = bool(ctx.get("player_visible", false))
	var noise_active: bool = bool(ctx.get("noise_active", false))
	var noise_pos: Vector2 = ctx.get("noise_pos", Vector2.ZERO)
	var base_sight: float = float(ctx.get("sight_range", 100.0))
	var angle: float = float(ctx.get("sight_angle_deg", SIGHT_ANGLE_DEFAULT))
	var hearing: float = float(ctx.get("hearing_range", 0.0))
	var light: float = float(ctx.get("light_factor", 1.0))

	var catch_player := false

	if visible:
		suspicion = minf(SUSPICION_THRESHOLD + 1.0, suspicion + SUSPICION_GAIN * delta)
		target_peer = int(ctx.get("target_peer", target_peer))
		state = State.CHASE
		if guard_pos.distance_to(player_pos) <= CATCH_DISTANCE:
			catch_player = true
	elif noise_active and hearing_reached(guard_pos.distance_to(noise_pos), hearing):
		suspicion = minf(SUSPICION_THRESHOLD, suspicion + SUSPICION_GAIN * delta)
		if state != State.CHASE:
			state = State.SUSPICIOUS
	else:
		suspicion = maxf(0.0, suspicion - SUSPICION_DECAY * delta)
		if suspicion <= 0.0 and state == State.SUSPICIOUS:
			state = State.PATROL

	return {
		"state": state,
		"target_peer": target_peer,
		"suspicion": suspicion,
		"catch_player": catch_player,
	}
```

> `ctx` 里的 `light_factor` 由场景层根据「路灯是否被拔」算好后传进来；纯逻辑层不关心路灯实体。

`data/guards.json`：

```json
[
  {
    "id": "old_chen",
    "name": "老陈",
    "sight_range": 96,
    "sight_angle_deg": 80,
    "hearing_range": 128,
    "lines": {
      "spotted": ["哎哎哎！那边谁啊？", "谁在那儿？"],
      "caught": ["我的萝卜呢？！", "又是你！"],
      "missing": ["我的萝卜去哪了……"]
    }
  }
]
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_guard_brain.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 守卫感知与状态机纯逻辑"
```

---

## Task 5: 捣蛋裁决规则（纯逻辑）

**Files:**
- Create: `scripts/game/rules.gd`
- Test: `tools/test_rules.gd`

**Interfaces:**
- Consumes: 无（不依赖 Task 3/4 的类，只用基本类型）
- Produces:
  - `class_name Rules extends RefCounted`
  - `Rules.evaluate(action: Dictionary, ctx: Dictionary) -> Dictionary`
    - `action = { "peer_id": int, "behavior_id": StringName, "target_id": int, "progress": float }`
    - `ctx = { "nearest_guard_distance": float, "guard_alerted": bool, "has_partner": bool, "needs_partner": bool, "guard_catch_distance": float }`
    - 返回 `{ "success": bool, "reason": String, "caught": bool }` —— **永远不含"扣分/扣命"字段**

- [ ] **Step 1: 写失败的测试**

`tools/test_rules.gd`：

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	# 安全时完成
	var r := Rules.evaluate(
		{"peer_id": 1, "behavior_id": &"steal_carrot", "target_id": 10, "progress": 1.0},
		{"nearest_guard_distance": 200.0, "guard_alerted": false, "has_partner": true,
		 "needs_partner": false, "guard_catch_distance": 24.0})
	fails += _check(bool(r["success"]), "守卫不在附近时捣蛋成功")
	fails += _check(not bool(r["caught"]), "安全时不被抓")

	# 守卫警觉且近 → 失败 + 被抓
	var r2 := Rules.evaluate(
		{"peer_id": 1, "behavior_id": &"steal_carrot", "target_id": 10, "progress": 1.0},
		{"nearest_guard_distance": 10.0, "guard_alerted": true, "has_partner": true,
		 "needs_partner": false, "guard_catch_distance": 24.0})
	fails += _check(not bool(r2["success"]), "被守卫盯着时捣蛋失败")
	fails += _check(bool(r2["caught"]), "被守卫盯着且距离近时被抓")

	# 需要搭档但没有 → 仍可完成（效率减半，不阻断）
	var r3 := Rules.evaluate(
		{"peer_id": 1, "behavior_id": &"prank_bench", "target_id": 10, "progress": 1.0},
		{"nearest_guard_distance": 200.0, "guard_alerted": false, "has_partner": false,
		 "needs_partner": true, "guard_catch_distance": 24.0})
	fails += _check(bool(r3["success"]), "缺搭档时仍能完成（不阻断）")

	# 进度不足 → 不算完成
	var r4 := Rules.evaluate(
		{"peer_id": 1, "behavior_id": &"steal_carrot", "target_id": 10, "progress": 0.4},
		{"nearest_guard_distance": 200.0, "guard_alerted": false, "has_partner": true,
		 "needs_partner": false, "guard_catch_distance": 24.0})
	fails += _check(not bool(r4["success"]), "进度不足不算完成")

	# 关键：任何情况下都不产生惩罚性字段
	for key in r.keys():
		fails += _check(not (key in ["penalty", "score_delta", "lives_lost", "eliminated"]),
			"返回不含惩罚字段 %s" % key)

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_rules.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `Rules` 类不存在

- [ ] **Step 3: 实现**

`scripts/game/rules.gd`：

```gdscript
class_name Rules
extends RefCounted

## 捣蛋裁决。纯函数。
##
## 设计约束（来自规格 §2 P1 零失败惩罚）：
##   * 返回值里**永远没有**扣分/扣命/淘汰字段
##   * "被抓"只是一个事件标记，由场景层用来把玩家送回出生点
##   * 缺搭档不阻断完成，只影响效率

const CATCH_DISTANCE := 24.0


static func evaluate(action: Dictionary, ctx: Dictionary) -> Dictionary:
	var progress: float = float(action.get("progress", 0.0))
	var nearest: float = float(ctx.get("nearest_guard_distance", 99999.0))
	var alerted: bool = bool(ctx.get("guard_alerted", false))
	var needs_partner: bool = bool(ctx.get("needs_partner", false))
	var catch_dist: float = float(ctx.get("guard_catch_distance", CATCH_DISTANCE))

	if progress < 1.0:
		return {"success": false, "reason": "in_progress", "caught": false}

	var caught := alerted and nearest <= catch_dist

	if caught:
		return {"success": false, "reason": "caught", "caught": true}

	# needs_partner 仅为效率提示，不阻断
	return {"success": true, "reason": "ok", "caught": false}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_rules.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 捣蛋裁决纯逻辑（零失败惩罚约束）"
```

---

## Task 6: Transport 抽象与 ENet 传输

**Files:**
- Create: `scripts/net/transport.gd`, `scripts/net/enet_transport.gd`
- Test: `tools/test_transport.gd`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class_name Transport extends RefCounted`，信号 `peer_connected(id: int)`、`peer_disconnected(id: int)`、`server_connected()`、`connection_failed()`；方法 `host(port: int, max_clients: int) -> Error`、`join(address: String, port: int) -> Error`、`poll() -> void`、`attach_to(mp: MultiplayerAPI) -> void`、`is_attached() -> bool`、`get_peer() -> MultiplayerPeer`、`get_peer_id() -> int`、`is_host() -> bool`、`peer_list() -> Array[int]`
  - `class_name ENetTransport extends Transport`

- [ ] **Step 1: 写失败的测试**

`tools/test_transport.gd`：

```gdscript
extends SceneTree

## 单进程双 Transport 的握手测试：
## 一个 host，一个 client，验证 peer_connected / peer_list / is_host。

var _host: ENetTransport
var _client: ENetTransport
var _fails := 0


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	_host = ENetTransport.new()
	var e := _host.host(27015, 4)
	_fails += _check(e == OK, "host 创建成功")
	_fails += _check(_host.is_host(), "host.is_host() 为 true")
	_fails += _check(_host.get_peer_id() == 1, "host peer id 为 1")

	_client = ENetTransport.new()
	var e2 := _client.join("127.0.0.1", 27015)
	_fails += _check(e2 == OK, "client 连接请求发出")

	var connected := false
	for i in 240:
		_host.poll()
		_client.poll()
		if _host.peer_list().size() == 1 and _client.peer_list().size() == 1:
			connected = true
			break
		await process_frame

	_fails += _check(connected, "双方互相看到对方")
	_fails += _check(_host.peer_list() == [2], "host 看到 peer 2，实际 %s" % str(_host.peer_list()))
	_fails += _check(_client.peer_list() == [1], "client 看到 peer 1，实际 %s" % str(_client.peer_list()))
	_fails += _check(not _client.is_host(), "client.is_host() 为 false")

	print("")
	if _fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % _fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_transport.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `ENetTransport` 类不存在

- [ ] **Step 3: 实现**

`scripts/net/transport.gd`：

```gdscript
class_name Transport
extends RefCounted

## 联网传输层抽象。Gameplay 层只认这个接口，不认具体实现。
##
## P1 只有 ENetTransport；P2 增加 SteamTransport（内部用 SteamMultiplayerPeer）。

signal peer_connected(id: int)
signal peer_disconnected(id: int)
signal server_connected()
signal connection_failed()

var _peer: MultiplayerPeer = null
var _attached := false


func host(_port: int, _max_clients: int) -> Error:
	push_error("Transport.host 未实现")
	return ERR_UNAVAILABLE


func join(_address: String, _port: int) -> Error:
	push_error("Transport.join 未实现")
	return ERR_UNAVAILABLE


func poll() -> void:
	pass


## 挂到 SceneTree 的 MultiplayerAPI 上。挂上之后由引擎每帧自动 poll，
## 本类不再重复 poll（避免同一 peer 被 poll 两次）。
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


func peer_list() -> Array[int]:
	var out: Array[int] = []
	if _peer == null:
		return out
	for p in _peer.get_peers():
		out.append(p)
	return out
```

`scripts/net/enet_transport.gd`：

```gdscript
class_name ENetTransport
extends Transport

## ENet 传输实现。开发期用它在同一台机器上开两个进程模拟多人。

var _enet: ENetMultiplayerPeer = null
var _reported_connected := false


func host(port: int, max_clients: int) -> Error:
	_enet = ENetMultiplayerPeer.new()
	var err := _enet.create_server(port, max_clients)
	if err != OK:
		connection_failed.emit()
		return err
	_peer = _enet
	return OK


func join(address: String, port: int) -> Error:
	_enet = ENetMultiplayerPeer.new()
	var err := _enet.create_client(address, port)
	if err != OK:
		connection_failed.emit()
		return err
	_peer = _enet
	return OK


func poll() -> void:
	if _enet == null or is_attached():
		return
	_enet.poll()
	var state := _enet.get_connection_status()
	if state == MultiplayerPeer.CONNECTION_CONNECTED:
		if not _reported_connected:
			_reported_connected = true
			server_connected.emit()
	elif state == MultiplayerPeer.CONNECTION_DISCONNECTED:
		connection_failed.emit()
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_transport.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

> 若 `peer_list()` 一直为空，检查是否需要 `await process_frame` 让 ENet 有机会收发——ENet 的 `poll()` 是同步的，但连接建立需要若干次 poll。

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: Transport 抽象与 ENet 传输实现"
```

---

## Task 7: Session 层（大厅、成员、回合）

**Files:**
- Create: `scripts/net/session.gd`
- Create: `scenes/lobby.tscn`, `scripts/ui/lobby_ui.gd`
- Test: `tools/test_session.gd`

**Interfaces:**
- Consumes: `Transport` / `ENetTransport`（Task 6）、`Mischief` / `MischiefDeck`（Task 3）
- Produces:
  - `class_name Session extends Node`，信号 `roster_changed(peers: Array[int])`、`round_started(deal: Array)`、`round_ended(summary: Dictionary)`
  - `Session.set_transport(t: Transport) -> void`
  - `Session.host_game(port: int = 27015) -> Error`
  - `Session.join_game(address: String, port: int = 27015) -> Error`
  - `Session.start_round() -> void`（仅房主可调）
  - `Session.end_round(summary: Dictionary = {}) -> void`（房主可提前「收工」）
  - `Session.is_host() -> bool`、`Session.peer_count() -> int`、`Session.deal() -> Array`
  - `Session` 里**不得出现 `Steam.` 调用**

- [ ] **Step 1: 写失败的测试**

`tools/test_session.gd`：

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	var s := Session.new()
	root.add_child(s)
	s.set_transport(ENetTransport.new())

	var e := s.host_game(27016)
	fails += _check(e == OK, "Session 托管成功")
	fails += _check(s.is_host(), "Session 是 host")
	fails += _check(s.peer_count() == 1, "房主自己算 1 人")

	# 回合：房主生成清单
	s.set_available_tags([&"carrot", &"hat", &"basket", &"chair", &"barrel",
		&"lamp", &"bench", &"pot", &"sign"])
	s.start_round()
	await process_frame
	fails += _check(s.deal().size() == 1, "单人局生成 1 份清单")
	fails += _check((s.deal()[0] as Array).size() == 3, "单人局 3 张牌，实际 %d" % (s.deal()[0] as Array).size())

	# 非房主不能开回合
	var s2 := Session.new()
	root.add_child(s2)
	s2.set_transport(ENetTransport.new())
	s2.join_game("127.0.0.1", 27016)
	# Session._process 会自动 poll 自己的 transport，这里只需等帧
	for i in 240:
		await process_frame
		if s2.peer_count() == 2:
			break
		await process_frame
	fails += _check(s2.peer_count() == 2, "客户端已入房，实际 %d" % s2.peer_count())
	fails += _check(not s2.is_host(), "客户端不是 host")
	s2.start_round()
	await process_frame
	fails += _check(s2.deal().is_empty(), "客户端不能自己开回合（清单为空）")

	# 房主提前收工
	s.end_round()
	await process_frame
	fails += _check(s.deal().is_empty(), "结束后清单清空")

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_session.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `Session` 类不存在

- [ ] **Step 3: 实现 Session**

`scripts/net/session.gd`：

```gdscript
class_name Session
extends Node

## 大厅 / 成员 / 回合。**本文件不允许出现 Steam. 调用**（P2 的 Steam 逻辑在 steam_transport.gd）。

signal roster_changed(peers: Array[int])
signal round_started(deal: Array)
signal round_ended(summary: Dictionary)

const DEFAULT_PORT := 27015
const ALL_MISCHIEFS := "res://data/mischief.json"

var _transport: Transport = null
var _deal: Array = []
var _available_tags: Array[StringName] = []


func set_transport(t: Transport) -> void:
	_transport = t


func set_available_tags(tags: Array[StringName]) -> void:
	_available_tags = tags


func host_game(port: int = DEFAULT_PORT) -> Error:
	if _transport == null:
		_transport = ENetTransport.new()
	var err := _transport.host(port, 6)
	if err == OK:
		roster_changed.emit(peers())
	return err


func join_game(address: String, port: int = DEFAULT_PORT) -> Error:
	if _transport == null:
		_transport = ENetTransport.new()
	var err := _transport.join(address, port)
	if err == OK:
		roster_changed.emit(peers())
	return err


## 把传输挂到 SceneTree 的 MultiplayerAPI 上。
##
## 真实对局在 host/join 成功后调用一次即可。**故意不放进 host_game/join_game**：
## 那样同一个进程里就没法并存两个 Session 实例（测试需要 host + client 同进程）。
func apply_to_multiplayer() -> void:
	if _transport != null:
		_transport.attach_to(multiplayer)


func _process(_delta: float) -> void:
	if _transport == null:
		return
	# 已挂到 multiplayer 的 peer 由引擎每帧 poll，这里不重复驱动
	if not _transport.is_attached():
		_transport.poll()


func is_host() -> bool:
	return _transport != null and _transport.is_host()


func peer_count() -> int:
	return 0 if _transport == null else _transport.peer_list().size() + 1


func peers() -> Array[int]:
	return [] if _transport == null else _transport.peer_list()


func deal() -> Array:
	return _deal


## 仅房主可调。生成每个人的捣蛋清单。
func start_round() -> void:
	if not is_host():
		return
	var all := Mischief.load_all(ALL_MISCHIEFS)
	if _available_tags.is_empty():
		for m in all:
			_available_tags.append(m.target_tag)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_deal = MischiefDeck.generate(all, peer_count(), rng, _available_tags)
	round_started.emit(_deal)


## 房主随时可以「收工」，不惩罚任何人。
func end_round(summary: Dictionary = {}) -> void:
	if not is_host():
		return
	_deal = []
	round_ended.emit(summary)
```

> **把 Session 注册成自动加载**，在 `project.godot` 里加：
> ```ini
> [autoload]
>
> Router="*res://scripts/ui/router.gd"
> Session="*res://scripts/net/session.gd"
> ```
> 这样大厅界面可以直接 `get_node("/root/Session")` 拿到它，
> 且切换到游戏场景后 Session 依然存活（大厅场景本身会被释放）。

- [ ] **Step 4: 大厅界面**

`scripts/ui/lobby_ui.gd`：

```gdscript
extends Control

## 大厅界面：显示成员列表、主机/加入按钮、开始按钮。

@onready var _roster: VBoxContainer = $Center/Panel/Margin/VBox/Roster
@onready var _status: Label = $Center/Panel/Margin/VBox/Status
@onready var _host_btn: Button = $Center/Panel/Margin/VBox/HostButton
@onready var _join_btn: Button = $Center/Panel/Margin/VBox/JoinButton
@onready var _start_btn: Button = $Center/Panel/Margin/VBox/StartButton

var _session: Session = null


func _ready() -> void:
	_session = get_node("/root/Session")
	_host_btn.pressed.connect(_on_host)
	_join_btn.pressed.connect(_on_join)
	_start_btn.pressed.connect(_on_start)
	_session.roster_changed.connect(_on_roster)
	_refresh()


func _on_host() -> void:
	_session.host_game()
	_session.apply_to_multiplayer()
	_status.text = "已创建房间，等待朋友加入…"


func _on_join() -> void:
	_session.join_game("127.0.0.1")
	_session.apply_to_multiplayer()
	_status.text = "正在加入…"


func _on_start() -> void:
	if _session.is_host():
		_session.start_round()
		get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_roster(_peers: Array[int]) -> void:
	_refresh()


func _refresh() -> void:
	for c in _roster.get_children():
		c.queue_free()
	for i in _session.peer_count():
		var l := Label.new()
		l.text = "玩家 %d" % (i + 1)
		_roster.add_child(l)
	_start_btn.disabled = not _session.is_host()
```

`scenes/lobby.tscn`（节点路径必须与 `lobby_ui.gd` 的 `@onready` 完全一致）：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/ui/lobby_ui.gd" id="1_lobby"]

[node name="Lobby" type="Control"]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1_lobby")

[node name="Center" type="CenterContainer" parent="."]
layout_mode = 1
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0

[node name="Panel" type="PanelContainer" parent="Center"]
layout_mode = 2

[node name="Margin" type="MarginContainer" parent="Center/Panel"]
layout_mode = 2

[node name="VBox" type="VBoxContainer" parent="Center/Panel/Margin"]
layout_mode = 2

[node name="Title" type="Label" parent="Center/Panel/Margin/VBox"]
layout_mode = 2
text = "镇长不在的时候"

[node name="Roster" type="VBoxContainer" parent="Center/Panel/Margin/VBox"]
layout_mode = 2

[node name="Status" type="Label" parent="Center/Panel/Margin/VBox"]
layout_mode = 2
text = "等待连接…"

[node name="HostButton" type="Button" parent="Center/Panel/Margin/VBox"]
layout_mode = 2
text = "创建房间"

[node name="JoinButton" type="Button" parent="Center/Panel/Margin/VBox"]
layout_mode = 2
text = "加入房间"

[node name="StartButton" type="Button" parent="Center/Panel/Margin/VBox"]
layout_mode = 2
text = "开始这一夜"
```

> 节点路径必须与上面 `@onready` 一致；建完场景后用 --import 验证能加载。

- [ ] **Step 5: 跑测试确认通过**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_session.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: Session 层与大厅界面"
```

---

## Task 8: 玩家角色与拥有者权威同步

**Files:**
- Create: `scenes/player.tscn`, `scripts/player.gd`
- Create: `scripts/game/world_map.gd`（关卡数据：地面尺寸 + 道具点位）
- Create: `data/map.json`
- Test: `tools/test_player.gd`

**Interfaces:**
- Consumes: 无
- Produces:
  - `class_name WorldMap extends RefCounted`，`static func load_map(path: String = "res://data/map.json") -> Dictionary`，返回 `{ "size": Vector2i, "props": { tag: Array[Vector2] } }`
  - `scripts/player.gd` 挂在 `CharacterBody2D` 上，导出 `speed: float = 150.0`、`player_index: int = 0`
  - `player.tscn` 结构：`Player(CharacterBody2D)` → `Sprite2D` + `CollisionShape2D` + `MultiplayerSynchronizer`

- [ ] **Step 1: 写失败的测试**

`tools/test_player.gd`：

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	var map := WorldMap.load_map()
	fails += _check(map.has("size"), "地图有 size")
	fails += _check((map["props"] as Dictionary).size() >= 6, "地图至少有 6 类道具")
	fails += _check((map["props"] as Dictionary).has("carrot"), "地图有 carrot 道具")

	var packed: PackedScene = load("res://scenes/player.tscn")
	fails += _check(packed != null, "player.tscn 可加载")
	if packed != null:
		var p := packed.instantiate()
		fails += _check(p.get_node_or_null("MultiplayerSynchronizer") != null, "玩家带 MultiplayerSynchronizer")
		var sync := p.get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
		if sync != null:
			var cfg := sync.replication_config
			fails += _check(cfg != null and cfg.has_property(^"position"), "position 在同步属性里")
			fails += _check(cfg != null and cfg.property_get_spawn(^"position"), "position 开启 spawn 同步")
		p.free()

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_player.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `WorldMap` 类不存在

- [ ] **Step 3: 地图数据与实现**

`data/map.json`：

```json
{
  "size": [30, 18],
  "props": {
    "carrot": [[4, 4]],
    "hat":    [[24, 4]],
    "basket": [[13, 2]],
    "chair":  [[12, 8], [13, 8], [14, 8], [15, 8]],
    "barrel": [[6, 12], [22, 12]],
    "lamp":   [[8, 6], [20, 6], [14, 14]],
    "bench":  [[5, 16], [24, 16]],
    "pot":    [[10, 10], [18, 10]],
    "sign":   [[15, 9]]
  }
}
```

`scripts/game/world_map.gd`：

```gdscript
class_name WorldMap
extends RefCounted

## 关卡数据：地面尺寸 + 各类道具的位置。纯数据。

const TILE := 32


static func load_map(path: String = "res://data/map.json") -> Dictionary:
	var out := {"size": Vector2i(30, 18), "props": {}}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("打不开地图数据: " + path)
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("地图数据不是对象: " + path)
		return out
	var size_arr: Array = parsed.get("size", [30, 18])
	out["size"] = Vector2i(int(size_arr[0]), int(size_arr[1]))
	var props := {}
	for tag in parsed.get("props", {}).keys():
		var arr: Array = parsed["props"][tag]
		var pts: Array[Vector2] = []
		for p in arr:
			pts.append(Vector2(float(p[0]) * TILE, float(p[1]) * TILE))
		props[StringName(tag)] = pts
	out["props"] = props
	return out
```

- [ ] **Step 4: 玩家场景与脚本**

`scripts/player.gd`：

```gdscript
extends CharacterBody2D

## 玩家角色。移动由**拥有者**权威计算，位置通过 MultiplayerSynchronizer 同步。

@export var speed: float = 150.0
@export var player_index: int = 0

@onready var sprite: Sprite2D = $Sprite2D

var _bob: float = 0.0


func _ready() -> void:
	# 节点名 = peer id，作为多人权威的依据
	var pid := int(name) if name.is_valid_int() else 1
	set_multiplayer_authority(pid)
	sprite.texture = load("res://assets/chars/char_%d.png" % (player_index % 6))


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		# 非拥有者：位置由同步器提供，只做表现
		_bob += delta * 8.0
		sprite.position.y = -absf(sin(_bob)) * 2.0
		return

	var dir := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_up", "ui_down"))
	if dir.length() > 1.0:
		dir = dir.normalized()
	velocity = velocity.lerp(dir * speed, 1.0 - exp(-12.0 * delta))
	move_and_slide()

	# 程序化行走动画：上下 bob + 轻微 squash（替代多帧序列帧）
	if dir != Vector2.ZERO:
		_bob += delta * 9.0
		sprite.position.y = -absf(sin(_bob)) * 3.0
		sprite.scale = Vector2(1.0 + sin(_bob * 2.0) * 0.04, 1.0 - sin(_bob * 2.0) * 0.04)
	else:
		_bob = 0.0
		sprite.position.y = 0.0
		sprite.scale = Vector2.ONE
```

`scenes/player.tscn`：

```
[gd_scene load_steps=4 format=3]

[ext_resource type="Script" path="res://scripts/player.gd" id="1_player"]
[ext_resource type="Texture2D" path="res://assets/chars/char_0.png" id="2_tex"]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_body"]
size = Vector2(20, 12)

[node name="Player" type="CharacterBody2D"]
script = ExtResource("1_player")

[node name="Sprite2D" type="Sprite2D" parent="."]
texture = ExtResource("2_tex")
offset = Vector2(-32, -64)

[node name="CollisionShape2D" type="CollisionShape2D" parent="."]
position = Vector2(0, -6)
shape = SubResource("RectangleShape2D_body")

[node name="MultiplayerSynchronizer" type="MultiplayerSynchronizer" parent="."]
replication_config = SubResource("SceneReplicationConfig_sync")
```

在 `player.tscn` 里加一个 sub_resource：

```
[sub_resource type="SceneReplicationConfig" id="SceneReplicationConfig_sync"]
properties/0/path = NodePath(".:position")
properties/0/spawn = true
properties/0/replication_mode = 1
```

> `replication_mode = 1` 即 `REPLICATION_MODE_ON_CHANGE`。

- [ ] **Step 5: 跑测试确认通过**

Run: --import
Run: `godot --headless --path . --quit-after 600 --script res://tools/test_player.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: 玩家角色与拥有者权威同步"
```

---

## Task 9: 守卫实体与追击、被抓送回出生点

**Files:**
- Create: `scenes/guard.tscn`, `scripts/guard.gd`
- Modify: `scripts/game/guard_brain.gd`（补 `CARRY` / `RETURN` 的转移规则）
- Test: `tools/test_guard_flow.gd`

**Interfaces:**
- Consumes: `GuardBrain`（Task 4）、`WorldMap`（Task 8）
- Produces:
  - `scripts/guard.gd`：`@export var guard_id: StringName`、巡逻点数组、调用 `GuardBrain.update()`，发出信号 `spotted(peer_id)`、`caught_player(peer_id)`
  - 被抓流程：`Scripts` 层提供 `GuardBrain.begin_carry(peer_id)` / `GuardBrain.finish_carry()`

- [ ] **Step 1: 写失败的测试**

`tools/test_guard_flow.gd`：

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	# 抓捕后进入 CARRY，押送结束后回到 PATROL
	var b := GuardBrain.new()
	b.state = GuardBrain.State.CHASE
	b.target_peer = 4
	b.begin_carry()
	fails += _check(b.state == GuardBrain.State.CARRY, "抓捕后进入 CARRY")
	fails += _check(b.target_peer == 4, "CARRY 保留目标")

	b.finish_carry()
	fails += _check(b.state == GuardBrain.State.RETURN, "押送结束进入 RETURN")

	# 怀疑度归零后回到 PATROL
	var b2 := GuardBrain.new()
	b2.suspicion = 0.0
	b2.state = GuardBrain.State.SUSPICIOUS
	var ctx := {"guard_pos": Vector2.ZERO, "guard_facing": Vector2.RIGHT,
		"player_pos": Vector2.ZERO, "player_visible": false, "noise_pos": Vector2.ZERO,
		"noise_active": false, "sight_range": 100.0, "sight_angle_deg": 80.0,
		"hearing_range": 0.0, "target_peer": 0}
	var r: Dictionary = b2.update(0.2, ctx)
	fails += _check(int(r["state"]) == GuardBrain.State.PATROL, "怀疑度归零回 PATROL")

	# 守卫场景可加载
	var packed: PackedScene = load("res://scenes/guard.tscn")
	fails += _check(packed != null, "guard.tscn 可加载")

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_guard_flow.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `begin_carry` 不存在

- [ ] **Step 3: 补 GuardBrain 的 CARRY/RETURN**

在 `scripts/game/guard_brain.gd` 的 `update()` 之前加：

```gdscript
## 抓捕开始：进入押送状态，保留目标。
func begin_carry() -> void:
	state = State.CARRY


## 押送结束：回岗位。
func finish_carry() -> void:
	state = State.RETURN
	suspicion = 0.0
```

并在 `update()` 开头加：

```gdscript
	if state == State.CARRY:
		return {"state": state, "target_peer": target_peer, "suspicion": suspicion, "catch_player": false}
	if state == State.RETURN and not visible and not noise_active:
		state = State.PATROL
```

- [ ] **Step 4: 守卫场景与脚本**

`scripts/guard.gd`：

```gdscript
extends Node2D

## 守卫实体。把场景信息喂给纯逻辑的 GuardBrain，再按结果驱动表现。
## AI 逻辑只在房主跑（权威在房主），这里不做任何联机判定。

signal spotted(peer_id: int)
signal caught_player(peer_id: int)

@export var guard_id: StringName = &"old_chen"
@export var patrol_radius: float = 120.0
@export var sight_range: float = 96.0
@export var sight_angle_deg: float = 80.0
@export var hearing_range: float = 128.0
@export var speed: float = 70.0

@onready var sprite: Sprite2D = $Sprite2D

## 由 game_scene.gd 在运行时注入（避免依赖场景路径）。
var player_root: Node2D = null

var brain: GuardBrain = GuardBrain.new()
var _home := Vector2.ZERO
var _patrol_angle := 0.0
var _target_position := Vector2.ZERO


func _ready() -> void:
	_home = global_position
	_patrol_angle = randf() * TAU
	set_physics_process(multiplayer.is_server())


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	var ctx := _sense_context()
	var result := brain.update(delta, ctx)
	var st := int(result["state"])

	match st:
		GuardBrain.State.PATROL:
			_patrol(delta)
		GuardBrain.State.SUSPICIOUS:
			_move_towards(_target_position, delta)
		GuardBrain.State.CHASE:
			var tp := _player_position(int(result["target_peer"]))
			if tp != Vector2.ZERO:
				_target_position = tp
				spotted.emit(int(result["target_peer"]))
			_move_towards(_target_position, delta)
			if bool(result["catch_player"]):
				caught_player.emit(int(result["target_peer"]))
				brain.begin_carry()
		GuardBrain.State.CARRY:
			pass
		GuardBrain.State.RETURN:
			_move_towards(_home, delta)
			if global_position.distance_to(_home) < 6.0:
				brain.finish_carry()
				brain.state = GuardBrain.State.PATROL

	if st == GuardBrain.State.CHASE:
		rotation = lerp_angle(rotation, (_target_position - global_position).angle(), 8.0 * delta)


## 组装给纯逻辑用的"世界快照"。找不到玩家就返回安全的空快照。
func _sense_context() -> Dictionary:
	var light := 1.0
	var nearest := 99999.0
	var visible := false
	var target_peer := 0
	var player_pos := Vector2.ZERO

	if player_root == null:
		return {"guard_pos": global_position, "guard_facing": Vector2.RIGHT,
			"player_pos": Vector2.ZERO, "player_visible": false,
			"noise_pos": Vector2.ZERO, "noise_active": false,
			"sight_range": sight_range, "sight_angle_deg": sight_angle_deg,
			"hearing_range": hearing_range, "target_peer": 0, "light_factor": light}

	for child in player_root.get_children():
		var n2d := child as Node2D
		if n2d == null:
			continue
		var d := global_position.distance_to(n2d.global_position)
		if d < nearest:
			nearest = d
			player_pos = n2d.global_position
			target_peer = int(child.name) if child.name.is_valid_int() else 1
		var facing := Vector2.RIGHT.rotated(rotation)
		if GuardBrain.in_sight_cone(global_position, facing, n2d.global_position,
				GuardBrain.effective_sight_range(sight_range, light), sight_angle_deg):
			visible = true

	return {"guard_pos": global_position, "guard_facing": Vector2.RIGHT.rotated(rotation),
		"player_pos": player_pos, "player_visible": visible,
		"noise_pos": Vector2.ZERO, "noise_active": false,
		"sight_range": sight_range, "sight_angle_deg": sight_angle_deg,
		"hearing_range": hearing_range, "target_peer": target_peer, "light_factor": light}


func _player_position(peer_id: int) -> Vector2:
	if player_root == null:
		return Vector2.ZERO
	var n := player_root.get_node_or_null(str(peer_id)) as Node2D
	return Vector2.ZERO if n == null else n.global_position


func _patrol(delta: float) -> void:
	_patrol_angle += delta * 0.35
	var target := _home + Vector2(cos(_patrol_angle), sin(_patrol_angle * 0.7)) * patrol_radius
	_move_towards(target, delta)
	rotation = lerp_angle(rotation, (target - global_position).angle(), 4.0 * delta)


func _move_towards(target: Vector2, delta: float) -> void:
	var dir := target - global_position
	if dir.length() < 1.0:
		return
	global_position += dir.normalized() * speed * delta
```

`scenes/guard.tscn`：

```
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/guard.gd" id="1_guard"]
[ext_resource type="Texture2D" path="res://assets/chars/char_5.png" id="2_tex"]

[node name="Guard" type="Node2D"]
script = ExtResource("1_guard")

[node name="Sprite2D" type="Sprite2D" parent="."]
texture = ExtResource("2_tex")
offset = Vector2(-32, -64)
```

- [ ] **Step 5: 跑测试确认通过**

Run: --import
Run: `godot --headless --path . --quit-after 600 --script res://tools/test_guard_flow.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat: 守卫实体、追击与押送状态"
```

---

## Task 10: 捣蛋交互与房主权威裁决

**Files:**
- Create: `scripts/game/interaction.gd`（纯逻辑：判定"玩家能否对目标开始捣蛋"）
- Create: `scripts/mischief_prop.gd`（场景节点：可被捣蛋的道具）
- Modify: `scripts/player.gd`（加入交互检测与 RPC 入口）
- Create: `scenes/mischief_prop.tscn`
- Test: `tools/test_interaction.gd`

**Interfaces:**
- Consumes: `Rules`（Task 5）、`Mischief`（Task 3）
- Produces:
  - `class_name Interaction extends RefCounted`，`Interaction.find_prop_in_range(player_pos: Vector2, props: Array, radius: float) -> Node`（返回最近的 `MischiefProp`）
  - `class_name MischiefProp extends Node2D`，导出 `prop_tag: StringName`、`prop_id: int`
  - RPC（放在 `scripts/player.gd` 或独立 `scripts/net/game_rpc.gd`）：
    - `@rpc("any_peer", "call_remote", "reliable") func submit_mischief(behavior_id: StringName, target_id: int) -> void`
    - `@rpc("authority", "call_local", "reliable") func resolve_mischief(peer_id: int, behavior_id: StringName, success: bool, reason: String) -> void`

- [ ] **Step 1: 写失败的测试**

`tools/test_interaction.gd`：

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	var scene := Node2D.new()
	var a := Node2D.new()
	a.set_meta("prop_tag", &"carrot")
	a.set_meta("prop_id", 7)
	a.position = Vector2(100, 0)
	scene.add_child(a)

	var b := Node2D.new()
	b.set_meta("prop_tag", &"lamp")
	b.set_meta("prop_id", 8)
	b.position = Vector2(140, 0)
	scene.add_child(b)

	var found = Interaction.find_prop_in_range(Vector2(105, 0), scene.get_children(), 40.0)
	fails += _check(found != null, "范围内能找到道具")
	if found != null:
		fails += _check(int(found.get_meta("prop_id")) == 7, "找到的是最近的道具（7），实际 %s" % str(found.get_meta("prop_id")))

	var none = Interaction.find_prop_in_range(Vector2(500, 500), scene.get_children(), 40.0)
	fails += _check(none == null, "范围外找不到道具")

	# 裁决接线：被守卫盯着就不能完成
	var r := Rules.evaluate(
		{"peer_id": 2, "behavior_id": &"steal_carrot", "target_id": 7, "progress": 1.0},
		{"nearest_guard_distance": 12.0, "guard_alerted": true, "has_partner": true,
		 "needs_partner": false, "guard_catch_distance": 24.0})
	fails += _check(not bool(r["success"]) and bool(r["caught"]), "被盯上时判定被抓")

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_interaction.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `Interaction` 类不存在

- [ ] **Step 3: 实现**

`scripts/game/interaction.gd`：

```gdscript
class_name Interaction
extends RefCounted

## 捣蛋交互的纯逻辑部分：找出玩家附近可交互的道具。


static func find_prop_in_range(player_pos: Vector2, props: Array, radius: float) -> Node:
	var best: Node = null
	var best_d := radius
	for p in props:
		var n2d := p as Node2D
		if n2d == null:
			continue
		var d := player_pos.distance_to(n2d.global_position)
		if d <= best_d:
			best_d = d
			best = n2d
	return best
```

`scripts/mischief_prop.gd`：

```gdscript
extends Node2D

## 一个可被捣蛋的道具。位置与 tag 来自 data/map.json。

@export var prop_tag: StringName = &""
@export var prop_id: int = 0


func _ready() -> void:
	set_meta("prop_tag", prop_tag)
	set_meta("prop_id", prop_id)
```

`scripts/net/game_rpc.gd`（挂在 `game.tscn` 的根节点上）：

```gdscript
extends Node

## 房主权威的捣蛋裁决。所有判定在房主跑，结果广播给所有人。

signal mischief_resolved(peer_id: int, behavior_id: StringName, success: bool, reason: String)
signal player_caught(peer_id: int)

const CATCH_DISTANCE := 24.0

## 由 game_scene.gd 在运行时注入（避免依赖场景路径）。
var players_root: Node2D = null
var guards_root: Node2D = null


@rpc("any_peer", "call_remote", "reliable")
func submit_mischief(behavior_id: StringName, target_id: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var ctx := _gather_context(sender)
	var outcome := Rules.evaluate(
		{"peer_id": sender, "behavior_id": behavior_id, "target_id": target_id, "progress": 1.0},
		ctx)
	resolve_mischief.rpc(sender, int(outcome["success"]), String(outcome["reason"]))


@rpc("authority", "call_local", "reliable")
func resolve_mischief(peer_id: int, success: bool, reason: String) -> void:
	mischief_resolved.emit(peer_id, &"", success, reason)
	if reason == "caught":
		player_caught.emit(peer_id)


func _gather_context(peer_id: int) -> Dictionary:
	var nearest := 99999.0
	var alerted := false
	if players_root != null and players_root.has_node(str(peer_id)):
		var me := players_root.get_node(str(peer_id)) as Node2D
		if guards_root != null and guards_root.get_child_count() > 0:
			var g := guards_root.get_child(0) as Node2D
			nearest = me.global_position.distance_to(g.global_position)
			var b = g.get("brain")
			alerted = b != null and int(b.state) == GuardBrain.State.CHASE
	return {"nearest_guard_distance": nearest, "guard_alerted": alerted,
		"has_partner": true, "needs_partner": false, "guard_catch_distance": CATCH_DISTANCE}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_interaction.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 捣蛋交互与房主权威裁决"
```

---

## Task 11: 镇子场景与 HUD

**Files:**
- Create: `scenes/game.tscn`, `scripts/game_scene.gd`
- Create: `scenes/ui/hud.tscn`, `scripts/ui/hud.gd`
- Test: `tools/test_game_scene.gd`

**Interfaces:**
- Consumes: `Session`（Task 7）、`WorldMap`（Task 8）、`MischiefProp`（Task 10）
- Produces:
  - `game.tscn` 节点路径：`Game` → `Ground`(Sprite2D) / `Props`(Node2D) / `Players`(Node2D) / `Guards`(Node2D) / `MultiplayerSpawner` / `RPC`(game_rpc.gd) / `HUD`(CanvasLayer)
  - `scripts/ui/hud.gd`：`set_card_list(titles: Array[String])`、`show_bubble(text: String)`、`set_hint(text: String)`

- [ ] **Step 1: 写失败的测试**

`tools/test_game_scene.gd`：

```gdscript
extends SceneTree

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0
	var packed: PackedScene = load("res://scenes/game.tscn")
	fails += _check(packed != null, "game.tscn 可加载")
	if packed != null:
		var g := packed.instantiate()
		for n in ["Ground", "Props", "Players", "Guards", "MultiplayerSpawner", "HUD"]:
			fails += _check(g.get_node_or_null(n) != null, "game.tscn 含 %s" % n)
		g.free()

	var hud: PackedScene = load("res://scenes/ui/hud.tscn")
	fails += _check(hud != null, "hud.tscn 可加载")
	if hud != null:
		var h := hud.instantiate()
		fails += _check(h.get_node_or_null("CardList") != null, "hud 含 CardList")
		fails += _check(h.get_node_or_null("Hint") != null, "hud 含 Hint")
		fails += _check(h.get_node_or_null("Bubble") != null, "hud 含 Bubble")
		h.free()

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_game_scene.gd   # 前置：先跑一次 --import`
Expected: FAIL —— `game.tscn` 不存在

- [ ] **Step 3: 场景与脚本**

`scripts/game_scene.gd`：

```gdscript
extends Node2D

## 镇子场景：铺地面、放道具、按 peer 生成玩家、驱动守卫与 HUD。

@onready var props_root: Node2D = $Props
@onready var players_root: Node2D = $Players
@onready var guards_root: Node2D = $Guards
@onready var spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var rpc_node = $RPC
@onready var hud = $HUD
@onready var ground: Sprite2D = $Ground

const PLAYER_SCENE := preload("res://scenes/player.tscn")
const PROP_SCENE := preload("res://scenes/mischief_prop.tscn")
const GUARD_SCENE := preload("res://scenes/guard.tscn")


func _ready() -> void:
	spawner.spawn_path = ^"../Players"
	spawner.add_spawnable_scene(PLAYER_SCENE.resource_path)
	_build_world()
	if multiplayer.is_server():
		_spawn_player(1)


func _build_world() -> void:
	var map := WorldMap.load_map()
	var size: Vector2i = map["size"]
	ground.texture = load("res://assets/ground/ground_grass.png")
	ground.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	ground.region_enabled = true
	ground.region_rect = Rect2(Vector2.ZERO, Vector2(size.x * 32, size.y * 32))

	var prop_id := 1
	for tag in (map["props"] as Dictionary).keys():
		for pos in (map["props"] as Dictionary)[tag]:
			var p := PROP_SCENE.instantiate()
			p.prop_tag = tag
			p.prop_id = prop_id
			p.position = pos
			props_root.add_child(p)
			prop_id += 1

	if multiplayer.is_server():
		var g := GUARD_SCENE.instantiate()
		g.position = Vector2(480, 288)
		guards_root.add_child(g)
		# 把 Players 引用注入守卫，守卫感知靠它而不是靠场景路径
		g.set("player_root", players_root)

	# 把 Players / Guards 引用注入 RPC 节点
	rpc_node.set("players_root", players_root)
	rpc_node.set("guards_root", guards_root)


func _spawn_player(peer_id: int) -> void:
	if players_root.has_node(str(peer_id)):
		return
	var p := PLAYER_SCENE.instantiate()
	p.name = str(peer_id)
	p.player_index = peer_id - 1
	p.position = Vector2(64, 288)
	players_root.add_child(p)


func _on_peer_connected(id: int) -> void:
	if multiplayer.is_server():
		_spawn_player(id)
```

`scripts/ui/hud.gd`：

```gdscript
extends CanvasLayer

## HUD：左上角捣蛋清单、右上角提示、中间吐槽气泡。

@onready var _card_list: VBoxContainer = $CardList
@onready var _hint: Label = $Hint
@onready var _bubble: Label = $Bubble
@onready var _bubble_timer: Timer = $BubbleTimer


func _ready() -> void:
	_bubble.visible = false
	_bubble_timer.timeout.connect(func(): _bubble.visible = false)


func set_card_list(titles: Array[String]) -> void:
	for c in _card_list.get_children():
		c.queue_free()
	for i in titles.size():
		var l := Label.new()
		l.text = "□ %s" % titles[i]
		_card_list.add_child(l)


func set_hint(text: String) -> void:
	_hint.text = text


func show_bubble(text: String) -> void:
	_bubble.text = text
	_bubble.visible = true
	_bubble_timer.start(2.5)
```

`scenes/mischief_prop.tscn`：

```
[gd_scene load_steps=3 format=3]

[ext_resource type="Script" path="res://scripts/mischief_prop.gd" id="1_prop"]
[ext_resource type="Texture2D" path="res://assets/props/prop_barrel.png" id="2_tex"]

[node name="MischiefProp" type="Node2D"]
script = ExtResource("1_prop")

[node name="Sprite2D" type="Sprite2D" parent="."]
texture = ExtResource("2_tex")
offset = Vector2(-16, -32)
```

`scenes/ui/hud.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/ui/hud.gd" id="1_hud"]

[node name="HUD" type="CanvasLayer"]
script = ExtResource("1_hud")

[node name="CardList" type="VBoxContainer" parent="."]
offset_left = 10.0
offset_top = 8.0
offset_right = 210.0
offset_bottom = 90.0

[node name="Hint" type="Label" parent="."]
anchors_preset = 1
anchor_left = 1.0
anchor_right = 1.0
offset_left = -220.0
offset_top = 8.0
offset_right = -10.0
offset_bottom = 26.0
horizontal_alignment = 2

[node name="Bubble" type="Label" parent="."]
anchors_preset = 5
anchor_left = 0.5
anchor_right = 0.5
offset_left = -180.0
offset_top = 40.0
offset_right = 180.0
offset_bottom = 70.0
horizontal_alignment = 1

[node name="BubbleTimer" type="Timer" parent="."]
one_shot = true
```

> `anchors_preset` 是编辑器写入的便捷属性，直接写 `anchor_left/anchor_right/offset_*` 即可。
> 若 Godot 导入后报锚点相关警告，删掉 `anchors_preset` 行保留后面的锚点数值。

`scenes/game.tscn`：

```
[gd_scene load_steps=5 format=3]

[ext_resource type="Script" path="res://scripts/game_scene.gd" id="1_game"]
[ext_resource type="Script" path="res://scripts/net/game_rpc.gd" id="2_rpc"]
[ext_resource type="Texture2D" path="res://assets/ground/ground_grass.png" id="3_ground"]
[ext_resource type="PackedScene" path="res://scenes/ui/hud.tscn" id="4_hud"]

[node name="Game" type="Node2D"]
script = ExtResource("1_game")

[node name="Ground" type="Sprite2D" parent="."]
texture = ExtResource("3_ground")
texture_repeat = 2
centered = false
z_index = -10

[node name="Props" type="Node2D" parent="."]

[node name="Players" type="Node2D" parent="."]

[node name="Guards" type="Node2D" parent="."]

[node name="MultiplayerSpawner" type="MultiplayerSpawner" parent="."]
spawn_path = NodePath("../Players")

[node name="RPC" type="Node" parent="."]
script = ExtResource("2_rpc")

[node name="HUD" parent="." instance=ExtResource("4_hud")]
```

- [ ] **Step 4: 跑测试确认通过**

Run: --import
Run: `godot --headless --path . --quit-after 600 --script res://tools/test_game_scene.gd   # 前置：先跑一次 --import`
Expected: PASS，退出码 0

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 镇子场景与 HUD"
```

---

## Task 12: 回合流程、结算与端到端冒烟测试

**Files:**
- Create: `scripts/ui/result_screen.gd`, `scenes/result.tscn`
- Create: `tools/test_smoke.gd`
- Modify: `scripts/net/session.gd`（补 `round_started` / `round_ended` 的广播）

**Interfaces:**
- Consumes: `Session`（Task 7）、`game_scene.gd`（Task 11）
- Produces:
  - `scripts/ui/result_screen.gd`：`show_summary(summary: Dictionary) -> void`，summary 结构 `{ peer_id: { name, done, caught, mischief_titles } }`
  - `tools/test_smoke.gd`：headless 跑完整一局

- [ ] **Step 1: 写端到端冒烟测试**

`tools/test_smoke.gd`：

```gdscript
extends SceneTree

## 端到端冒烟：加载 game 场景 → 开回合 → 生成清单 → 模拟一次捣蛋 → 结束回合。

func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	var fails := 0

	var packed: PackedScene = load("res://scenes/game.tscn")
	fails += _check(packed != null, "game.tscn 可加载")
	if packed == null:
		print("TEST FAILED")
		quit(1)
		return

	var game := packed.instantiate()
	root.add_child(game)
	for i in 5:
		await process_frame

	var session: Session = root.get_node_or_null("Session")
	fails += _check(session != null, "Session 自动加载存在")
	if session == null:
		print("TEST FAILED")
		quit(1)
		return

	# 用一个自建的 Session 实例当房主（autoload 那个没有开房，不是 host）
	var host_session := Session.new()
	root.add_child(host_session)
	host_session.host_game(27017)
	host_session.set_available_tags([&"carrot", &"hat", &"basket", &"chair", &"barrel",
		&"lamp", &"bench", &"pot", &"sign"])
	host_session.start_round()
	await process_frame

	fails += _check(host_session.deal().size() == 1, "开局生成 1 份清单")
	fails += _check((host_session.deal()[0] as Array).size() == 3, "清单 3 张")

	# 模拟一次捣蛋裁决（本地直接调用；headless 下没有 multiplayer peer，
	# 用 .rpc() 会报 "Cannot get RPC config"，所以直接调方法）
	var rpc_node = game.get_node_or_null("RPC")
	fails += _check(rpc_node != null, "RPC 节点存在")
	if rpc_node != null:
		rpc_node.resolve_mischief(1, true, "ok")
		await process_frame

	# 结束回合
	host_session.end_round()
	await process_frame
	fails += _check(host_session.deal().is_empty(), "结束后清单清空")

	print("")
	if fails == 0:
		print("TEST PASSED")
		quit(0)
	else:
		print("TEST FAILED: %d 项" % fails)
		quit(1)


func _check(ok: bool, what: String) -> int:
	print(("  [PASS] " if ok else "  [FAIL] ") + what)
	return 0 if ok else 1
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --quit-after 600 --script res://tools/test_smoke.gd   # 前置：先跑一次 --import`
Expected: FAIL —— 缺少 Session / RPC 接线

- [ ] **Step 3: 结算页**

`scripts/ui/result_screen.gd`：

```gdscript
extends Control

## 结算：每人一张「通缉令」。不做排行榜、不做成就。

@onready var _cards: HBoxContainer = $Center/Panel/Margin/HBox


func show_summary(summary: Dictionary) -> void:
	for c in _cards.get_children():
		c.queue_free()
	for peer_id in summary.keys():
		var info: Dictionary = summary[peer_id]
		var box := VBoxContainer.new()
		var title := Label.new()
		title.text = "玩家 %s" % str(info.get("name", peer_id))
		box.add_child(title)
		var stat := Label.new()
		stat.text = "捣蛋 %d 次    被抓 %d 次" % [int(info.get("done", 0)), int(info.get("caught", 0))]
		box.add_child(stat)
		var list := VBoxContainer.new()
		for t in info.get("mischief_titles", []):
			var l := Label.new()
			l.text = "· %s" % str(t)
			list.add_child(l)
		box.add_child(list)
		_cards.add_child(box)
```

- [ ] **Step 4: 跑全部测试**

```bash
godot --headless --path . --import
godot --headless --path . --quit-after 120
# 全套测试建议直接用统一入口（自动做 import -> test 两步）：
#   powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1
for t in project art mischief_deck guard_brain rules transport session player guard_flow interaction game_scene smoke; do
  godot --headless --path . --quit-after 600 --script res://tools/test_$t.gd || exit 1
done
```
Expected: 全部 `TEST PASSED`，且 `--quit-after 120` 无 ERROR / 无 WARNING

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 回合流程、结算页与端到端冒烟测试"
```

---

## Task 13: 双窗口手动验收清单

**Files:**
- Create: `docs/manual-test-p1.md`

**Interfaces:**
- Consumes: 全部
- Produces: 一份可照着做的手动验收清单

- [ ] **Step 1: 写清单**

`docs/manual-test-p1.md`：

```markdown
# P1 手动验收清单

## 准备
1. Godot 编辑器打开项目，确认无报错
2. 编辑器设置 `Debug → Run Multiple Instances = 2`
3. 按 F5，开出两个窗口

## 步骤
- [ ] 窗口 A 点「创建房间」，窗口 B 点「加入」
- [ ] 两边成员列表都显示 2 人
- [ ] 窗口 A 点「开始」，两边同时进入镇子
- [ ] 两个角色都能移动，且**互相看得见对方在动**
- [ ] 走近老陈，顶部出现「按 E 与老陈交谈」
- [ ] 按 E 打开捣蛋面板，能看到 3 张清单
- [ ] 对着萝卜按 E 触发捣蛋，进度条走完后清单打勾
- [ ] 老陈发现你 → 追你 → 抓住 → 你被送回出生点，**清单进度还在**
- [ ] 完成全部清单 → 结算页出现「通缉令」卡片
- [ ] 按 ESC 关闭结算 → 回到大厅，可以再来一局

## 判废条件（出现任意一条即判 P1 不通过）
- 被抓后清单进度被清零（违反零失败惩罚）
- 两个窗口看到的成员数不一致
- 角色位置在两个窗口不同步
- 出现任何 ERROR / WARNING
```

- [ ] **Step 2: 提交**

```bash
git add -A
git commit -m "docs: P1 手动验收清单"
```

---

## P1 完成后怎么办

P1 通过后，**停**。不要继续写 P2/P3 的代码。按顺序：

1. 用 `after-hours` 项目跑一次完整的手动验收（Task 13）
2. 写 `docs/superpowers/plans/2026-11-03-after-hours-p2-steam.md`（Steam 接入）
3. P2 完成后写 P3（内容与手绘美术），P3 是体量最大的一期
