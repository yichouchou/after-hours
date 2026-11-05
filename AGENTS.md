# AGENTS.md

《镇长不在的时候》(After Hours) —— Godot 4.7 的 2D 多人潜行原型（抓迷藏 + 捣蛋任务卡）。
逻辑分辨率 640×360，ENet 联机，开发分支 `main`。

## 强制：所有 Godot 开发一律走 godot-ai 桥接

对本项目做的**任何** Godot 开发与优化操作——读场景树、改节点属性、写/改脚本、把游戏跑起来看效果、截图取证、查日志——都必须在**正在运行的 Godot 编辑器**里通过 godot-ai MCP 桥接完成。**不要再写一次性 PowerShell / GDScript 探针去旁路编辑器。**

例外：headless 测试不是编辑器操作，仍走 `tools/run_tests.ps1`（桥接也不跑测试套件）。

- MCP 配置（已就绪）：`D:\minimax-code\agent-space\.minimax\mcp.json` → `mcpServers.godot-ai`，stdio，`command = C:\Users\75996\.local\bin\godot-ai.exe`，`args = ["attach"]`
- 编辑器插件：`addons/godot_ai/`（v4.4.1，**MIT 许可，已纳入版本控制**）。`project.godot` 里的 `[editor_plugins]` 与 `_mcp_game_helper` autoload 与它**同进同退**（干净检出即可直接用桥接）。★ 插件仍需用户在编辑器 UI 里启用一次；外部改写 `project.godot` 会被运行中的编辑器覆盖
- 后端由插件拉起并持有（HTTP 8000 / WS 9500，带 `--owner-pid`）。**不要自己另起一个 attach 后端**去抢端口
- 连通性自检：`mcp__godot-ai__session_manage(op="list")` 返回 `count=0` = 编辑器没接上，先让用户开编辑器并确认插件已启用

| 目的 | 调用 |
|---|---|
| 编辑器状态 / 当前场景 | `editor_state` |
| 场景树 / 节点属性 | `scene_get_hierarchy`、`node_get_properties`、`node_find` |
| 改场景 | `node_create`、`node_set_property`、`node_manage(op=...)`、`ui_manage`、`camera_manage` |
| 写 / 改脚本 | `script_create`、`script_patch`、`script_attach`、`script_manage(op="read"/"find_symbols")` |
| 跑起来 | `project_run(mode="main")`、`project_manage(op="stop")` |
| 取证 | `editor_screenshot(source="game")`、`logs_read(source="editor"/"game"/"plugin")` |
| 在运行中的游戏里执行 GDScript | `editor_manage(op="game_eval", params={code:"..."})` |

已踩过的坑（照此绕开）：

1. **数值参数会被序列化成字符串**：`input_mouse` / `input_action` / `max_depth` 这类要传数字的调用会直接类型报错。需要精确数值时改用 `editor_manage(op="game_eval")` 在游戏里跑 GDScript；定位、移动、存图要放在**同一次** eval 里，否则守卫会跑开。
2. **`Router` autoload 启动一帧后无条件 `goto(LOBBY_SCENE)`**：命令行 `godot --path <repo> res://scenes/game.tscn` 会被踢回大厅。要进对局场景，用 game_eval 里 `change_scene_to_file`。
3. **不要再手搓 PowerShell 截图探针**：OpenGL 窗口用 `PrintWindow` 只能抓到黑屏，全屏抓会混进用户自己的窗口。
4. **改 `project.godot` 走编辑器 UI**，不要外部改写。

## 常用命令

Godot 不在 PATH，可执行文件：

- GUI：`D:\Godot\Godot_v4.7.2-stable_win64.exe`
- 控制台：`D:\Godot\Godot_v4.7.2-stable_win64_console.exe`

```powershell
# 全量测试（唯一入口）
powershell -ExecutionPolicy Bypass -NoProfile -File tools\run_tests.ps1

# 单跑一个测试（干净检出必须先 --import，否则 load() 返回 null 被误报成失败）
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --import
& 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path D:\GodotProjects\after-hours --quit-after 600 --script 'res://tools/test_guard_flow.gd'
```

判定通过 = 退出码 0 **且**输出含 `TEST PASSED`（两者都要看，`--quit-after` 兜底退出时退出码也是 0）。

端口：测试用 `tools/port_alloc.gd` 动态分配（27100–27299），**禁止硬编码 270xx**；生产默认 28000。

## 项目结构

- `scenes/` — main / lobby / game / player / guard / result / ui·hud / mischief_prop
- `scripts/game/` — 纯逻辑层（rules、mischief、mischief_deck、guard_brain、interaction、world_map），**不得触碰场景树**
- `scripts/net/` — 联机（transport、enet_transport、session、game_rpc、peer_state）
- `scripts/ui/` — UI 逻辑
- `tools/` — headless 测试与辅助脚本（`test_*.gd` + `run_tests.ps1`）
- `docs/gameplay-guide.md` — 玩家向玩法说明（含"当前版本的已知限制"清单）
- `assets/` `data/` — 美术与数据
- `addons/godot_ai/` — godot-ai 编辑器插件（MIT，**已纳入版本控制**，与 `project.godot` 同进同退）
- `.superpowers/sdd/2026-11-03-after-hours-p1-vertical-slice/` — 设计与实施文档，**被 `.superpowers/sdd/.gitignore` 忽略、不进 git**；本机完整约束见其中 `global-constraints.md`

## 硬性约束

- **零失败惩罚**：玩法里不存在失败 / 扣分 / 扣命 / 淘汰 / 死亡。返回值、变量名、函数名和**注释**里都不得出现 `penalty`、`penalized`、`score`、`score_delta`、`lives`、`lives_lost`、`eliminated`、`damage`、`扣分`、`扣命`、`淘汰`、`死亡`；`hp` 按**独立词**匹配。`tools/test_player.gd`、`tools/test_guard_flow.gd`、`tools/test_game_scene.gd` 会逐文件扫描源码。
- `scripts/game/**` 是纯逻辑层：禁止 `get_tree()`、`get_node()` 和任何场景节点引用。
- Gameplay 层禁止直接调用 `Steam.`。
- 联机：判定一律在房主侧完成；玩家位置以该 peer 的拥有者为权威；场景节点之间禁止硬编码绝对路径。
- `Router`、`Session` 是 autoload。
- **守卫朝向走 `facing_angle` 字段，节点 `rotation` 恒为 0**——贴图带偏移，转节点会让人物绕着脚底翻倒。
- 命名：类名 PascalCase、文件名 snake_case、私有成员 `_` 前缀。
- 编码：新文件 UTF-8 无 BOM + LF；`.ps1` 必须带 UTF-8 BOM。
- 提交：每个任务结束必须 git commit；**不要 `git add -A`**，按文件显式添加；未经用户明确要求不 push。

## 环境事实

- 引擎 4.7.2.stable，渲染后端 `gl_compatibility`
- 逻辑分辨率 640×360，窗口 1280×720，`window/stretch/mode="canvas_items"`
- 生产端口 28000；测试端口由 `tools/port_alloc.gd` 动态分配
