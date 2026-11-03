# 《镇长不在的时候》/ After Hours —— 设计规格

- **版本**：v1.0（设计已口头确认，本文为书面固化）
- **日期**：2026-11-03
- **状态**：待评审
- **引擎**：Godot 4.7.2-stable（GL Compatibility 后端）
- **联机**：Steam Lobby + P2P（开发期用 ENet 本地双窗口模拟）
- **美术**：手绘 2D 俯视
- **定位**：2-6 人派对捣蛋，零失败惩罚，3-5 分钟一局

---

## 1. 一句话与商店页定位

> **朋友之间的捣蛋时间。2-6 人，没有输家，只有越来越离谱的镇子。**

- **类型**：多人派对 / 非对称捣蛋 / 轻喜剧
- **Steam 标签**：Party, Casual, Co-op, Multiplayer, Funny
- **目标玩家**：和朋友一起开的 2-6 人小队，想玩点不出戏、不掉分、随时能退出的东西
- **一句话差异化**：
  1. **零失败惩罚** —— 被抓只是喜剧事件，不是挫败
  2. **活的 AI 守卫** —— 会被气到、会记仇、会针对具体某个玩家吐槽（同类产品没有）

---

## 2. 三条不可动摇的设计支柱

| 支柱 | 具体含义 | 违反它的后果（反面例子） |
|---|---|---|
| **P1 零失败惩罚** | 任何玩家的任何行为都不导致淘汰、扣分、掉命或提前退场 | "被抓到就少一条命"→ 变成对抗游戏，玩家会互相坑 |
| **P2 一局 3-5 分钟** | 随时可以开一局、随时可以结束 | 15 分钟的长局 → 不解压，变成负担 |
| **P3 内容是加法** | 1 张地图 + N 种行为组合出所有局，不做 M 张地图 | 每加一个人就要重做一套关卡 → 成本爆炸 |

**范围纪律（强制）**：第一版不做账号系统、匹配系统、排行榜、成就系统（用结算页"通缉令"替代）、自定义关卡上传、任何内购。

---

## 3. 核心循环

```
┌─ 大厅（Steam Lobby）
│    房主建大厅 → 朋友接受邀请 → 最多 6 人
└─ 开局
     ├─ 房主掷种子 → 生成每人的「捣蛋清单」（2人3张 / 3人4张 / 4-6人5张）
     ├─ 夜晚开始，守卫开始巡逻
     │
     ├─ ★ 自由行动 ★
     │    ├─ 找到目标（萝卜/椅子/路灯/告示板/狗…）
     │    ├─ 执行捣蛋行为（有进度条，1-3 秒）
     │    ├─ 可能被发现 → 守卫追击
     │    ├─ 被抓到 → 护送回镇口起点（不扣分），失去手中道具
     │    └─ 逃脱 → 完成，清单打勾
     │
     └─ 结束条件：所有人的清单全部完成
          ├─ 房主可以随时点「收工」提前结束（不惩罚任何人，仅跳过剩余内容）
          └─ 结算：生成「今晚通缉令」（每人一张），列出干了什么、被抓几次、最离谱的一件
```

**没有倒计时**。进度条可见但不催人。守卫的追击是"可选的紧张感"，不是"必输的倒计时"。

**为什么清单永远不会卡死**：被抓只是丢道具、进度不清零，清单项可以无限重试。唯一的"卡死"情况是某个玩家挂机不动——此时房主点「收工」即可跳过，不会让其他人干等。

---

## 4. 玩法系统

### 4.1 捣蛋行为清单（Mischief）

行为分 5 类，共 20 种（Phase 3 补齐；Phase 1 先做 10 种）。

| 类 | 标识 | 数量 | 设计意图 |
|---|---|---|---|
| 偷窃 | `steal` | 4 | 拿了要放回去（被发现=手里东西掉地上） |
| 破坏 | `mess` | 4 | 现场留痕，守卫看到痕迹会起疑 |
| 恶作剧 | `prank` | 4 | **需要双人配合**，找不到搭档可单人完成但效率减半 |
| 布置 | `decor` | 4 | 把东西放到奇怪的地方，纯粹搞笑不触发守卫 |
| 声音 | `noise` | 4 | 主动吸引守卫，为队友的偷窃做掩护 |

**行为定义样例**：

| id | 名称 | 类 | 目标 | 说明 |
|---|---|---|---|---|
| `steal_carrot` | 偷走杂货铺的萝卜 | steal | 萝卜 | 拿到后放回原位才算完成 |
| `mess_chairs` | 把广场椅子堆成塔 | mess | 椅子 ×4 | 完成后椅子保持塔状，可被撞倒 |
| `prank_hat` | 偷换镇长的帽子 | prank | 镇长帽子 + 稻草人 | 需两人同时操作 |
| `decor_swing` | 把秋千挂到树上 | decor | 秋千 | 不触发守卫，纯搞笑 |
| `noise_pot` | 敲锅 | noise | 锅 | 发出声响，附近守卫前来查看 |

**清单生成规则**（房主执行）：
1. 从 20 种中随机抽 N 张（N = clamp(玩家数 + 1, 3, 5)）
2. 至少 1 张 `noise` 或 `decor`（保证永远有"保底可做"的行为，不会卡关）
3. 至少 1 张 `prank`（保证有双人配合的空间，2 人局也能凑合）
4. 同类不超过 2 张
5. 目标道具必须在本局地图上存在，否则重抽

**关键设计：清单不会因为失败而卡死**。被抓只是丢道具，重来即可。玩家永远不会"过不了关"。

### 4.2 守卫 NPC

3 个守卫，各有不同触发条件（这是地图玩法的核心）：

| 守卫 | 触发条件 | 特点 | AI 台词风格 |
|---|---|---|---|
| **镇长** | 视野最远（6 格），不看声音 | 迟钝但一旦发现就穷追不舍 | "谁把我的自行车推到池塘里了？" |
| **老陈** | 视野短（3 格），但**萝卜被偷立刻警觉** | 贪吃，会去追萝卜 | "我的萝卜呢？！第几次了？" |
| **酒馆老板** | 听力范围 8 格，视野只有 2 格 | 循声而来 | "谁在敲锅？出来！" |

**守卫状态机**：`巡逻 → 怀疑 → 追击 → 抓获 → 返回岗位`

**视野规则（与捣蛋行为耦合）**：
- 锥形视野 + 距离 + **光照影响**：每盏被熄灭的路灯让其覆盖半径内的守卫视野缩短 40%（路灯覆盖半径 5 格）
- 这让"关路灯"从搞笑行为升级为**战术行为**——先关灯再偷萝卜

### 4.3 被抓与重置（P1 的具体落地）

被抓时：
1. 玩家被"护送"（一小段牵引动画）回**自己的出生点**（镇口两侧，每人有固定位置）
2. **不扣分、不掉命、不淘汰**，只是失去手中未交付的道具
3. 屏幕弹出被守卫的吐槽气泡
4. 立刻可以继续，不影响其他人

被抓次数**只用于结算页的通缉令文案**（"你今晚被抓了 3 次"），不产生任何惩罚性后果。

### 4.4 结算：今晚通缉令

不做排行榜、不做成就。每个玩家一张"通缉令"卡片：

```
┌─────────────────────────────────────┐
│         镇 长 不 在 的 时 候         │
│            —— 第 7 个夜晚 ——         │
│                                     │
│   玩家：老李                          │
│   捣蛋成功 4 次    被抓 3 次           │
│                                     │
│   今夜最离谱：                        │
│   「把镇长的自行车铃铛挂在了酒馆      │
│     门把手上，还按了 17 次」          │
│                                     │
│   镇长评价：又来了？                  │
└─────────────────────────────────────┘
```

最后一行是 AI 守卫对这个玩家的**个性化评价**（见 §6）。这是整个产品的社交货币——玩家会互相截图。

---

## 5. 联机架构

### 5.1 分层设计

```
┌─────────────────────────────────────────┐
│  Gameplay 层（RPC 消息、玩法状态）        │  ← 永远不变
├─────────────────────────────────────────┤
│  Session 层（大厅、成员、开始/结束）       │
├─────────────────────────────────────────┤
│  Transport 层（可替换的 MultiplayerPeer） │
│    ├─ SteamMultiplayerPeer（生产）       │
│    └─ ENetMultiplayerPeer（开发/本地）   │
└─────────────────────────────────────────┘
```

**核心约束：Gameplay 层不允许出现任何 `Steam.` 调用。** 所有 Steam 相关代码集中在 `Transport` 和 `Session` 两个文件里。开发期用 ENet + Godot 的 "Run Multiple Instances = 2" 开双窗口测试，**上线时只换 Transport 实现，上层一行不改**。

### 5.2 权威模型（混合权威）

| 系统 | 权威方 | 同步方式 | 理由 |
|---|---|---|---|
| 玩家移动 | **拥有者** | MultiplayerSynchronizer | 手感必须跟手，不能有延迟 |
| 捣蛋行为裁决 | **房主** | RPC 请求 → 房主判定 → 广播结果 | 判定要一致，且能防作弊 |
| 守卫 AI | **房主** | 只广播守卫位置/状态 | AI 逻辑重，集中跑省 CPU 且不会分歧 |
| 物理互动道具（椅子/垃圾桶） | **房主** | 房主跑物理 → 广播状态 | 堆叠/推倒必须全局一致 |
| 清单与结算 | **房主** | 房主生成 → 广播 | 保证所有人看到同一份清单 |

### 5.3 RPC 协议

```gdscript
# 客户端 → 房主
@rpc("any_peer", "call_remote", "reliable")
func submit_mischief(behavior_id: StringName, target_id: int) -> void

@rpc("any_peer", "call_remote", "reliable")
func report_input(input_vector: Vector2) -> void   # 房主跑物理时用

# 房主 → 所有人
@rpc("authority", "call_local", "reliable")
func resolve_mischief(peer_id: int, behavior_id: StringName, success: bool, reason: String) -> void

@rpc("authority", "call_local", "reliable")
func guard_state(guard_id: int, state: int, position: Vector2, target_peer: int) -> void

@rpc("authority", "call_local", "reliable")
func player_caught(peer_id: int, guard_id: int) -> void

@rpc("authority", "call_local", "reliable")
func round_start(seed_value: int, lists: Dictionary) -> void

@rpc("authority", "call_local", "reliable")
func round_end(summary: Dictionary) -> void
```

### 5.4 断线处理（范围裁剪）

**房主掉线 = 本局结束，重开一局，不做 host migration。**

理由：这符合"解压"定位——朋友中途掉线不该让全场罚站等重连。一局才 3-5 分钟，重开成本极低。实现复杂度直接砍掉一半。

玩家掉线：其角色从场景移除，其余玩家不受影响，继续玩。

### 5.5 Steam 接入要点（已调研确认）

| 事项 | 结论 |
|---|---|
| GodotSteam 版本 | 用 **4.23.2 GDExtension 预编译包**（支持 Godot 4.4+，4.7.2 实测可用） |
| 扩展放置 | `addons/godotsteam/`，重启编辑器生效 |
| 加载检查 | `Engine.has_singleton("Steam")` 和 `ClassDB.class_exists("SteamMultiplayerPeer")` 都必须为 true |
| 开发 App ID | 项目根放 `steam_appid.txt` 内容 `480`（Spacewar，Valve 公共测试 App） |
| Host | `peer.host_with_lobby(lobby_id)` + `peer.server_relay = true` |
| Client | `peer.connect_to_lobby(lobby_id)`，仅在 `Steam.getLobbyOwner() != Steam.getSteamID()` 时执行 |
| **已知坑** | `lobby_joined` 信号新版 4 参数 / 旧版 3 参数 → 必须写**参数数量适配器**，否则 Godot 4 直接报硬错误 |
| **已知坑** | Steam 覆盖层在编辑器内 + Forward+ 渲染器下不工作；**Compatibility 后端正常**（本项目用 gl_compatibility，天然规避） |
| **已知坑** | `Steam.run_callbacks()` 必须每帧泵调用，除非开启 "Embed Callbacks" |

---

## 6. AI 守卫（差异化核心）

### 6.1 分层策略：模板 + 大模型

| 层 | 内容 | 触发 | 延迟 |
|---|---|---|---|
| **L1 模板** | 每个守卫 10-15 句预写台词，按事件类型分组 | 抓到玩家、丢失物品、看见异常 | 0ms |
| **L2 记忆** | 记录"这个玩家第几次偷我东西"、"他最常捣什么乱" | 结算页 | 0ms |
| **L3 大模型** | 用 L2 记忆 + 当前事件生成个性化吐槽 | **仅结算页**，每玩家 1 次 | 1-3 秒 |

**关键约束**：大模型**绝不出现在实时玩法里**。实时对话必须是模板，否则延迟和成本都不可控。L3 只负责结算页那一句"镇长评价"——那是最值钱、最需要个性化的一个点。

### 6.2 API 调用约束

- 端点：`https://api.minimax.cn/anthropic/v1/messages`，模型 `MiniMax-M3.1-Flash`，`effort: low`
- 一局最多 6 次调用（每人 1 次）
- 同一守卫 10 秒内不重复请求
- 超时 5 秒 → 自动降级到 L1 模板，**绝不让结算页卡住**
- Key 三处查找：`res://secrets/minimax_key.txt` → `user://minimax_key.txt` → 环境变量 `MINIMAX_API_KEY`
- **无 Key 时整个 L3 层静默跳过**，游戏照常运行

### 6.3 记忆数据结构

```gdscript
{
  "player_id": 3,
  "display_name": "老李",
  "times_caught": 3,
  "mischiefs_by_type": {"steal": 2, "mess": 1, "noise": 1},
  "signature_mischief": "steal_carrot",   # 最常干的
  "worst_mischief": "mess_lamps",          # 最离谱的
  "guard_grudge": {"old_chen": 2, "mayor": 1}
}
```

---

## 7. 美术方向（手绘 2D）

### 7.1 视角与规格

- **俯视 3/4 视角**（Stardew Valley 式），不是正俯视也不是横版
- 逻辑分辨率 **640×360**，窗口 **1280×720**（整数 2 倍放大）
- 纹理过滤 Nearest 不用（手绘风用线性过滤更自然）——**与 Pixel Town 的像素管线刻意区分**
- 地面层 64×64 手绘瓦片；建筑、道具、角色为独立立绘

### 7.2 AI 素材生产管线（关键策略）

**不要让 AI 生成 tileset**（接缝与风格一致性无法保证）。策略是：

```
AI 生成「单个物体」→ 自动去背 → 直接作为 Sprite2D 贴图
地面 = 一张 AI 生成的手绘俯视地面纹理，程序化平铺
角色 = 一张 AI 生成角色立绘，程序化动画（不用多帧序列）
```

| 素材类型 | 数量 | 产出方式 | 动画策略 |
|---|---|---|---|
| 地面纹理 | 1-2 张（草/石/土） | AI 生成大图 → 程序平铺 | — |
| 建筑 | 4-6 张 | AI 生成俯视房屋 → 去背 | 静态 |
| 道具 | 15-20 张 | AI 生成单个物体 → 去背 | 静态 / 轻微摆动 |
| 角色 | 6 个（每人一个外观）+ 3 个守卫 | AI 生成角色立绘 → 去背 | **程序化**：走路时上下 bob + squash/stretch |
| UI 素材 | 按钮/卡片/灯笼/通缉令边框 | 手绘或 AI 生成后描边 | — |

**角色动画用程序化而非多帧序列**——这是本项目美术风险控制的核心决策：AI 无法稳定生成 4 方向 × 3 帧一致的序列帧，但单张立绘 + 代码驱动的 bob/squash 效果完全可控，且观感自然（大量独立游戏就这么做）。

### 7.3 角色外观的区分度

6 个玩家必须一眼分清。策略：**固定 6 套配色 + 固定 6 套服饰特征**（帽子/围巾/发型/体型），AI 按固定描述生成，保证一致性。玩家在开局界面选外观并显示在角色上方名牌上。

---

## 8. 音频

| 类型 | 内容 | 产出方式 |
|---|---|---|
| 环境音 | 夜晚虫鸣、微风、远处酒馆 | AI 生成或素材库 |
| 音效 | 捣蛋完成、抓捕、守卫"喂！"/"站住！"、脚步、推倒 | AI 生成或合成 |
| BGM | 一首轻快的夜曲 | MiniMax 音乐生成 |

第一版用程序合成音效兜底（参考 Pixel Town 的 `gen_assets.py` 方案），后期再替换。

---

## 9. 关键数据结构

```gdscript
class_name Mischief
extends Resource

@export var id: StringName
@export var title: String
@export var category: StringName      # steal / mess / prank / decor / noise
@export var target_tags: Array[String] # 需要的目标类型
@export var needs_partner: bool
@export var duration: float            # 行为持续时间（秒）
@export var points: int                # 仅用于结算排序，不是惩罚分
```

```gdscript
class_name Guard
extends Node2D

@export var guard_id: StringName
@export var sight_range: float
@export var sight_angle_deg: float
@export var hearing_range: float
@export var personality: StringName    # 台词风格分组
@export var patrol_points: Array[Vector2]
```

---

## 10. 目录结构

```
after-hours/
├── project.godot
├── addons/godotsteam/                # Steam GDExtension（Phase 2）
├── steam_appid.txt                    # 内容 480，仅开发期
├── scenes/
│   ├── main.tscn                      # 启动 → 大厅
│   ├── lobby.tscn                     # 成员列表 + 开始
│   ├── game.tscn                      # 镇子 + 玩家 + 守卫 + HUD
│   ├── player.tscn
│   ├── guard.tscn
│   └── ui/…
├── scripts/
│   ├── net/
│   │   ├── transport.gd               # Transport 接口 + 工厂
│   │   ├── steam_transport.gd         # SteamMultiplayerPeer 封装
│   │   ├── enet_transport.gd          # 开发期 ENet
│   │   └── session.gd                 # 大厅/成员/开始结束
│   ├── game/
│   │   ├── round.gd                   # 一局的状态机
│   │   ├── mischief.gd                # 行为定义与清单生成
│   │   ├── guard.gd                   # 守卫 AI
│   │   ├── guard_brain.gd             # 感知（视野/听觉）
│   │   └── rules.gd                   # 裁决（谁完成、谁被抓）
│   ├── ai/
│   │   └── guard_persona.gd           # 模板 + 记忆 + 大模型
│   └── ui/…
├── data/
│   ├── mischief.json                   # 20 种行为定义（数据驱动，参照 Pixel Town 的做法）
│   ├── guards.json                    # 3 个守卫 + 台词库
│   └── characters.json                # 6 套角色外观描述
├── assets/
│   ├── ground/  props/  chars/  ui/  audio/
└── docs/superpowers/specs/            # 本文档
```

---

## 11. 阶段规划

| Phase | 内容 | 周期 | 验收标准 |
|---|---|---|---|
| **P0** | 设计规格 + 行为清单 + 地图草图 | 1 周 | 本文档评审通过 |
| **P1** | **可玩垂直切片**：ENet 本地双人 + 1 张地图 + 10 种行为 + 1 个守卫 + 抓获重置 + HUD | 3-4 周 | 双窗口能一起玩，完整跑通一局 |
| **P2** | Steam 接入：GodotSteam + 大厅 + 邀请 + 真 Steam 双账号联机 | 1-2 周 | 两台电脑经 Steam 大厅联上 |
| **P3** | 内容与美术：20 种行为 + 3 个守卫 + 手绘素材 + 通缉令结算 | 4-6 周 | 3 局不重复，通缉令可截图 |
| **P4** | AI NPC：L3 个性化评价 + 记忆系统 | 1-2 周 | 结算页吐槽因人而异 |
| **P5** | Steam 上架：导出模板、图标、商店页、**AI 披露文案** | 2 周 | 提交审核 |

**P1 是唯一的硬门槛**：P1 不通过，后面全部不成立。P1 的美术用占位色块即可。

---

## 12. 风险与对策

| # | 风险 | 概率 | 影响 | 对策 |
|---|---|---|---|---|
| R1 | GodotSteam 与 4.7.2 兼容问题 | 中 | 阻塞 P2 | P1/P2 之间预留 1 周缓冲；Transport 抽象让 ENet 路径始终可交付 |
| R2 | AI 素材风格/一致性崩坏 | **高** | 阻塞 P3 | 物体级生成而非 tileset；角色单图 + 程序动画；关键素材人工修 |
| R3 | 内容消耗快，3 局就腻 | **高** | 致命 | 清单生成器 + 目标位置随机化；P5 后开放"自定义清单"做长线 |
| R4 | AI 调用成本/延迟 | 中 | 体验 | L3 只在结算页调用（每人 1 次）；5 秒超时降级模板 |
| R5 | 房主掉线全场卡住 | 中 | 体验 | 不做迁移，本局结束重开（符合解压定位） |
| R6 | Steam 中国区/全球发行合规 | 中 | 上架 | 全球 Steam + 中文本地化；AI 披露提前准备 |
| R7 | 6 人同屏性能（守卫 AI + 物理） | 低 | 性能 | 守卫 AI 只在房主跑；客户端只渲染；物理对象数量上限 |

---

## 13. Steam 上架与 AI 披露

- 商店页标签：Party / Casual / Co-op / Multiplayer / Funny / 2-6 Players
- 需要做的：图标、胶囊图、4-8 张截图、1 段 30-60 秒预告（**可用已有的 MiniMax H3 视频管线生成**）、Steam 页面文案
- **AI 披露（必须提前做）**：运行时实时生成的 NPC 台词属于 Steam 要求披露的类别。披露文案在 **P5 之前**就要定稿，不能等提交前临时写
- **开发期**用 `steam_appid.txt` = 480（Spacewar）测试；上线必须换成自有 App ID，且 `steam_appid.txt` 不得进发行包

---

## 14. 明确不做（防蔓延）

- ❌ 账号系统 / 登录
- ❌ 匹配系统（只做 Steam 大厅 + 好友邀请）
- ❌ 排行榜 / 成就系统
- ❌ 排位 / 赛季 / 天梯
- ❌ 自定义关卡编辑器
- ❌ 语音聊天（用 Steam 好友语音即可，不重复造）
- ❌ 内购 / 货币
- ❌ 房主迁移 / 断线重连
- ❌ 移动端（Steam Deck 兼容性另测）
