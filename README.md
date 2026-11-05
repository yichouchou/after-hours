# 《镇长不在的时候》 After Hours

2–6 人的 Godot 4.7 派对潜行原型：镇长今晚不在，几个夜里睡不着的人溜进广场，
趁着看门的**老陈**打盹，把手上的「捣蛋清单」一条条做完，做完就收工回家。

你是捣蛋的那个，**老陈是抓你的那个**。被抓不扣任何东西，只是被抓的那一条要重做。

- 引擎：Godot **4.7.2.stable**，渲染后端 `gl_compatibility`
- 逻辑分辨率 **640×360**，窗口 1280×720，`stretch/mode = "canvas_items"`
- 联机：ENet（server-relay），生产端口 `28000`
- 当前阶段：**P1 垂直切片**（可玩、可联机、玩法闭环已通）

---

## 快速开始

```powershell
# 用 Godot 4.7.2 打开这个目录（不是打开 project.godot 文件，是打开目录）
& 'D:\Godot\Godot_v4.7.2-stable_win64.exe' --path D:\GodotProjects\after-hours
```

进游戏后：

1. 大厅点 **「创建房间」**
2. 点 **「开始这一夜」** → 进对局
3. **方向键或 WASD** 移动，**按住 `E`** 在道具旁捣蛋
4. 做完清单点右下角 **「收工」**（只有房主能点）

> Godot 窗口默认不抢键盘焦点。进对局后按键没反应，先在窗口里**点一下鼠标**。

### 双窗口联机（本机）

```powershell
# 窗口 A（房主）
powershell -ExecutionPolicy Bypass -NoProfile -File tools\run_game.ps1
# 窗口 B（客户端）
powershell -ExecutionPolicy Bypass -NoProfile -File tools\run_game.ps1 -Second
```

窗口 A 点「创建房间」，窗口 B 点「加入房间」，两边都就位后**窗口 A** 点「开始这一夜」。
端口固定 `28000`，地址固定 `127.0.0.1`。两端都会自动切进对局场景。

---

## 玩法速览

| 操作 | 按键 |
|---|---|
| 移动 | 方向键（← ↑ → ↓）**或** WASD |
| 捣蛋 | **按住** `E`（走到目标道具 40 px 以内） |
| 收工 | 右下角「收工」按钮（只有房主能点） |

- **捣蛋清单**：开局时房主给每人发一份（3–5 张）。左上角显示的是**你自己那一份**。
- **目标道具**：萝卜、帽子、篮子、椅子、木桶、路灯、长椅、花盆、告示牌。
- **老陈（守卫）**：看见你就追，抓到你就把你押回自己的出生点。
  视野 96 px、听觉 128 px；**拔掉路灯**会让他的视野乘 0.6（每盏灭灯 −40%）。
- **「敲响酒馆的锅」会真的出声** —— 128 px 内的老陈会起疑，并朝声音走过去看看。
  这是唯一一张能主动把老陈引过来的牌。
- **零失败惩罚**：没有扣分、没有扣命、没有淘汰。被抓只是手上那一条作废。

完整说明（含数值表与「当前版本的已知限制」诚实清单）见
[`docs/gameplay-guide.md`](docs/gameplay-guide.md)。

---

## 跑测试

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tools\run_tests.ps1
```

`tools/run_tests.ps1` 是**唯一入口**：先 `--import` 导入资源，再逐个跑 `tools/test_*.gd`
（headless）。判定通过 = **退出码 0 且输出含 `TEST PASSED`**（两个信号都要看 ——
`--quit-after` 兜底退出时退出码也是 0，只看退出码会把失败误判成通过）。

单跑一个测试（干净检出必须先 `--import`，否则 `load()` 返回 null 被误报成失败）：

```powershell
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --import
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --quit-after 600 --script 'res://tools/test_guard_flow.gd'
```

端口：测试用 `tools/port_alloc.gd` 动态分配（27100–27299），**禁止硬编码 270xx**；
生产默认 `28000`。

---

## 项目结构

```
scenes/          main / lobby / game / player / guard / result / ui·hud / mischief_prop
scripts/game/    纯逻辑层（rules、mischief、mischief_deck、guard_brain、interaction、world_map）
                 —— 不得触碰场景树（禁 get_tree() / get_node()）
scripts/net/     联机（transport、enet_transport、session、game_rpc、peer_state）
scripts/ui/      UI 逻辑（router、lobby_ui、hud）
tools/           headless 测试与辅助脚本（test_*.gd + run_tests.ps1 + 素材流水线）
assets/          美术素材（角色 / 道具 / 地面 / 灯光贴图）
data/            地图与捣蛋行为表（map.json、mischief.json）
docs/            玩法说明、验收清单、设计与实施文档
addons/godot_ai/ godot-ai 编辑器插件（MIT）
```

### 素材流水线

美术素材是脚本生成的（AI 手绘绘本风），改完跑一遍：

```powershell
python tools\gen_art_ai.py --kind char|prop|tile
python tools\gen_light_texture.py
python tools\bake_map_ground.py
```

---

## 给 AI 协作者的约定

看 [`AGENTS.md`](AGENTS.md)：强制走 godot-ai 桥接的操作方式、硬性约束
（零失败惩罚 / 纯逻辑层隔离 / 联机权威模型 / 命名与编码规范 / 提交纪律）。

---

## 授权

代码与美术素材：本仓库自有。
`addons/godot_ai/` 是第三方插件，MIT 许可（见 `addons/godot_ai/LICENSE`）。
