# 美术重做设计规格：手绘绘本风（地图 / 人物 / 道具 / 灯光）

- 日期：2026-11-05
- 项目：《镇长不在的时候》(After Hours)，Godot 4.7.2，逻辑分辨率 640×360，窗口 1280×720，`stretch/mode="canvas_items"`
- 分支：`feature/p1-vertical-slice`
- 状态：待用户审阅

## 1. 背景与问题

实机抓图（`probe_out/art_before_01.png`）显示当前观感差，根因有四条，全部实测确认：

1. **10 个道具共用同一个椭圆**：`tools/gen_placeholder_art.py:79` 的 `prop()` 只画一个椭圆加高光，换个颜色就当胡萝卜 / 木桶 / 花盆 / 小狗 / 路灯用 → 玩家认不出道具。
2. **地面是一整片深蓝噪点**：`ground_grass.png` 基色 `(38,44,62)`，平铺 960×576 无任何结构；`ground_path.png` 这个土路贴图**存在但从未被使用**。
3. **角色是圆头 + 方块身子**，64×64 贴图被窗口放大 2 倍后模糊成一团。
4. **地图左侧 40% 是纯黑虚空**：镜头运行时挂在玩家身上（`game_scene.gd:_attach_camera`），玩家出生在地图最左列（tile 2,9 → px 64），相机中心在 x=64，视口向左溢出地图 256px，直接露出 clear color。

另外两处会让"换美术"踩雷的技术耦合点：

- **角色永远朝右**：`player.gd` / `guard.gd` 只用 `sprite.position.y` 做上下浮动，没有 `flip_h`。
- **贴图几何被测试钉住**：`test_player.gd:27` 的 `ALPHA_CENTER_X = 32 / ALPHA_BOTTOM = 64` 要求"不透明像素必须贴到画布最底边"+"视觉中心水平居中"；`test_art.gd` 钉死"地面 256×256 / 角色 64×64 / 道具 32×32"；`test_interaction.gd:348` 钉死"道具贴图高 32 且图片下沿落在 y=0"。

## 2. 目标与非目标

**目标**：地图、人物、道具统一换成手绘绘本风；地图变成有结构的镇子（含土路）；边缘不再出现黑虚空；角色会随朝向左右翻转；路灯真的发光，熄灯玩法在画面上成立。

**非目标**：不改任何玩法规则、数值、联机逻辑；不做角色动画帧（仍是单张立绘 + 程序化浮动）；不做 2D 骨骼；不做 UI 皮肤重做（HUD 面板另开一轮）。

## 3. 画风与素材来源

**画风：手绘绘本风**（用户已定）。参考已产出的样张（`workspace/probe_out/artgen/style_probe_sheet.png`）：厚描边、平涂低饱和、水粉质感、纯白底、角色为 Q 版三头身。

**来源：AI 生成 + 离线归一化**（方案 A，用户已认同）。链路已实测跑通：

```
mcode-tools connector call connector__matrix__generate_image   # 文本/图生图，requests 数组
  → success_items[].node_id
mcode-tools get_asset_url <node_id>                            # 取下载 URL
mcode-tools connector call connector__matrix__remove_image_background
  → 透明 PNG（1024²，alpha 包围盒正常）
  → PIL 归一化 → assets/
```

**风格一致性**：除第 1 张外，后续所有图都用**第 1 张样张作 image-to-image 风格锚点**（`generate_image` 的 `input_urls`），这是把 19 张素材压在同一画风里的关键手段。

**兜底**：某张图连续 3 轮不过关，则对那一张单独走程序化重绘（保留 PIL 路径），不拖累全局。

## 4. 素材规格

### 4.1 为什么按 2x 出图

窗口 1280×720 / 逻辑 640×360 → 画面实际是 2 倍像素。现在 64px 的角色贴图被放大 2 倍铺在 128px 上，模糊是"丑"的一大来源。**素材按 2x 出图、Sprite2D `scale = (0.5, 0.5)`**，世界里的占位与碰撞完全不变，但采样是 1:1。

实测依据（`_tmp_task14/probe_art_geom.gd`）：`Sprite2D.get_rect()` 返回**纹理空间**矩形、**不含节点 scale**；`offset = (-w/2, -h)` + `scale = 0.5` 时世界底边 = 0.0、世界中心 x = 0.0 → 自动锚定公式对任意尺寸与 scale 成立。

### 4.2 角色（贴图 128×128，世界 64×64）

| 文件 | 内容 |
|---|---|
| `assets/chars/char_0..char_5.png` | 6 个村民，服装颜色沿用现有调色板（红 / 蓝 / 绿 / 黄 / 紫 / 棕） |
| `assets/chars/char_guard.png` | 巡夜守卫：深色制服 + 帽子 + 手提灯 |

守卫单独一张的原因：`guard.tscn` 现在复用 `char_5.png`，而 `test_player.gd:383` 钉着"player_index = -1 → char_5.png"，`char_5` 必须留给村民。

**不变量**：不透明像素贴到画布最底边、水平中心居中。由归一化脚本强制保证，测试无需为每张图改数字。

### 4.3 道具（世界尺寸 → 2x 贴图）

| tag | 世界 | 贴图 | 备注 |
|---|---|---|---|
| carrot | 16×16 | 32×32 | |
| hat | 20×14 | 40×28 | |
| basket | 26×20 | 52×40 | |
| chair | 26×28 | 52×56 | 广场椅 4 张 |
| barrel | 26×30 | 52×60 | 木桶 2 个 |
| lamp | 22×56 | 44×112 | 路灯 3 盏，1.75 格高 |
| bench | 56×24 | 112×48 | 长椅 2 个 |
| pot | 24×24 | 48×48 | 花盆 2 个 |
| sign | 22×40 | 44×80 | 告示牌（守卫岗位） |
| dog | 30×22 | 60×44 | |

**不变量**：同角色——底边贴地、水平居中。

### 4.4 地面与灯光

| 文件 | 尺寸 | 说明 |
|---|---|---|
| `assets/ground/map_ground.png` | 960×576 | **烘焙产物**：草地底纹 + 手绘土路 + 四边压暗，一次成图，无接缝 |
| `assets/ground/ground_grass.png` | 256×256 | 烘焙源（保留） |
| `assets/ground/ground_path.png` | 256×256 | 烘焙源（保留，原本闲置，这次用上） |
| `assets/light/lamp_light.png` | 256×256 | 径向渐变点光源贴图，程序化生成 |

地面尺寸保持 1x：它是柔和的大面积纹理，模糊不可感，而 1920×1152 的 PNG 体积不划算。

### 4.5 影子

AI 出图自带接地影子就沿用；不带则在归一化时由 PIL 补一个柔和椭圆（宽 = 贴图宽 ×0.7，高 = 贴图高 ×0.18，居中贴底）。补的影子对称，不破坏"中心居中"不变量。

## 5. 地图结构（土路）

`data/map.json` 新增 `paths` 段，格式 `[[格x, 格y, 宽, 高], ...]`（原点左上，单位=格，每项一块矩形路段），布局原则：

- 一条主路：从西侧出生点（tile 2,9）向东贯穿到中央广场（告示牌 tile 15,9）。
- 三条支路：分别通往北侧篮子（13,2）、东侧帽子（24,4）、南侧木桶区（22,12）。
- 路面从道具密集处经过，让"捣蛋路线"在视觉上可读。

`paths` 是**素材流水线的数据**（烘焙脚本读它）；运行时不解析、不消费——地面已烘焙成单图，运行时不需要路径信息。烘焙时路段边缘用不规则笔触做起伏，四边各 24px 做亮度渐变压到 35%，让地图边缘不再是硬边。

## 6. 灯光（2D）

当前游戏**完全没有灯光渲染**。本轮补上，让"拔掉街上的路灯"在画面上成立。

| 元素 | 实现 |
|---|---|
| 夜色 | `scenes/game.tscn` 加 `CanvasModulate`，色值起步 `Color(0.70, 0.72, 0.88)`（轻度偏蓝），靠实机截图调 |
| 光源 | 每盏灯挂一个 `PointLight2D`（`assets/light/lamp_light.png`，暖黄 `Color(1.0, 0.92, 0.72)`），`texture_scale = 0.95` → 光池半径 ≈ 120px（256px 贴图半宽 128px × 0.95），与"熄灯 160px 内视野 ×0.6"的玩法影响半径同量级 |
| 灯灭 | 灯灭时 `PointLight2D.visible = false`，同时灯的 `Sprite2D.modulate` 压暗成 `Color(0.55, 0.55, 0.65)` |
| HUD | HUD 在独立 `CanvasLayer` → **不受 CanvasModulate 影响**，清单文字保持清晰 |

**灯光同步放在道具自己身上**：每个灯道具在 `MischiefProp._process` 里读自己的亮灭状态并同步 `PointLight2D.visible`，不由 `game_scene` 每帧遍历所有道具——状态跟着道具走，天然同步。

**读取路径收口**：灯的亮灭契约是 `meta "lamp_on"` → 属性 `lamp_on` → 都没有就当亮着（现在只有 `guard.gd::_lamp_is_on()` 在读，`interaction.gd:set_lamp_on()` 在写）。本轮把这个规则上移到 `Interaction.is_lamp_on(node)`（纯逻辑层，允许读节点自身属性、**不碰场景树**），`guard.gd::_lamp_is_on()` 改为委托它，灯光同步也调它。**单一读取路径，行为不变**——`test_interaction.gd` 的 [§4-16] 钉的是行为（熄灯 → `light_factor` 1.0→0.6 → 守卫视野变小 → 重新点亮恢复），不是读取位置，改动后仍全绿。

**兼容风险与回退**：`gl_compatibility` 后端支持 2D 灯光，但必须实机验证。若不生效或效果不可接受，回退方案 = 把灯光烘焙进地面图（灯下亮斑）+ 保留 CanvasModulate 夜色，功能不丢。

## 7. 代码改动清单

| # | 文件 | 改动 |
|---|---|---|
| 1 | `scripts/mischief_prop.gd` | 新增 `apply_texture(tex)`：设 `Sprite2D.texture` 并按 `offset = (-w/2, -h)` 自动锚定；新增 `_process`：若身上挂了 `PointLight2D`，按 `Interaction.is_lamp_on(self)` 同步 `light.visible` 与 `Sprite2D.modulate`（亮=本色，灭=`Color(0.55,0.55,0.65)`） |
| 2 | `scripts/game_scene.gd` | `_build_props` 改调 `apply_texture`；`GROUND_TEXTURE` → `res://assets/ground/map_ground.png`；为 lamp 道具挂 `PointLight2D`；`_attach_camera` 里设 `limit_left/top/right/bottom = 0/0/960/576` |
| 3 | `scripts/player.gd` | `SPRITE_SCALE := 0.5`；浮动动画改成 `Vector2.ONE * SPRITE_SCALE * (...)`；按水平速度做 `flip_h`：`|velocity.x| > 8` 时翻转，翻转后保持 0.15s 滞回（防抖） |
| 4 | `scripts/guard.gd` | `_lamp_is_on()` 委托 `Interaction.is_lamp_on`；按 `facing_angle` 做 `flip_h`：`absf(facing.x) > 0.35` 时翻转，0.15s 滞回；**节点 `rotation` 恒为 0，绝不动** |
| 5 | `scripts/game/interaction.gd` | 新增 `static func is_lamp_on(node) -> bool`（单一读取路径） |
| 6 | `scenes/player.tscn` / `scenes/guard.tscn` | `Sprite2D.scale = (0.5, 0.5)`；`guard.tscn` 贴图 → `char_guard.png` |
| 7 | `scenes/mischief_prop.tscn` | `Sprite2D.scale = (0.5, 0.5)`；`offset` 交给脚本按贴图尺寸算 |
| 8 | `scenes/game.tscn` | 新增 `CanvasModulate`（夜色） |
| 9 | `data/map.json` | 新增 `paths` 段 |
| 10 | `tools/art_manifest.json` + `tools/gen_art_ai.py` | 素材流水线：清单 → 批量生成 → 抠图 → 归一化 → 写 `assets/`（清单格式见下） |
| 11 | `tools/bake_map_ground.py` | 地面烘焙：草地 + 土路 + 边缘压暗 → `map_ground.png` |
| 12 | `assets/art_sources.json` | 每张素材的 prompt / node_id / 工具名，便于换风格重生成 |

**纯逻辑层约束不被破坏**：`scripts/game/**` 仍然不出现 `get_tree()` / `get_node()` / 场景节点引用；新增的 `Interaction.is_lamp_on` 只读节点自身的 meta 与属性。

### 7.1 素材清单格式

`tools/art_manifest.json` 每项如下（公共风格前缀由脚本统一拼在 `prompt` 前，避免每张重复写）：

```json
{
  "out": "assets/chars/char_0.png",
  "kind": "char",
  "world_size": [64, 64],
  "prompt": "a chibi villager in a red jacket, full body standing, facing right",
  "style_ref": null,
  "anchor": "feet"
}
```

- `kind`：`char` | `prop` | `tile`（`tile` = 可平铺纹理，如草地/土路；产出后交给烘焙脚本，不直接进 `assets/ground/` 之外的运行时路径）
- `world_size`：世界尺寸（char/prop）；贴图实际尺寸 = 世界尺寸 × 2；`tile` 固定 256×256
- `style_ref`：风格锚点图的 `assets/` 路径；第 1 张为 `null`，其余都指向第 1 张，脚本把它作为 `generate_image` 的 `input_urls`
- `anchor`：`feet` = 底边贴地 + 水平居中（char/prop 适用；tile 不适用）

## 8. 测试契约更新

| 文件 | 改动 |
|---|---|
| `tools/test_art.gd` | 新契约表：`map_ground.png` 960×576（**新增断言**）；`ground_grass.png` / `ground_path.png` 保持 256×256（现断言不变）；`char_0..5` + `char_guard` 各 128×128；10 个道具按 §4.3 逐个查表；`lamp_light.png` 256×256。**新增锚点断言**：每张角色/道具贴图的 alpha 包围盒必须贴到画布底边、水平中心居中（把美术不变量变成测试） |
| `tools/test_interaction.gd` | [§4-14] 由"道具贴图高 == 32"改为"等于该道具贴图实际高度"（动态读 `texture.get_height()`），**"图片下沿落在 y = 0" 保留**；[§4-16] 行为断言不变，另加一条"熄灯后对应 `PointLight2D.visible == false`" |
| `tools/test_player.gd` | `ALPHA_CENTER_X` 32→64、`ALPHA_BOTTOM` 64→128（2x 贴图；不变量本身不变） |
| `tools/test_guard_flow.gd` | 同上常量调整；守卫"节点 rotation 恒为 0"的断言保留 |

## 9. 验收标准

1. `tools/run_tests.ps1` 全绿（现有 16 个测试，契约更新后仍为 16 个）。
2. 用 godot-ai 桥接抓**改造前后同机位对比图**（改造前已有：`probe_out/art_before_01.png`）。
3. 10 种道具逐一可辨认（用户确认）。
4. 玩家随移动左右翻转；守卫转身不翻倒（`rotation` 恒为 0）。
5. 地图边缘不再出现纯黑虚空（相机钳制到地图内）。
6. 熄灯后对应光池消失、画面变暗；HUD 清单文字不受夜色影响。
7. `assets/art_sources.json` 记录全部素材来源，换风格可复现。

## 10. 风险与对策

| 风险 | 对策 |
|---|---|
| AI 出图风格漂移 | 用第 1 张样张作 image-to-image 锚点；单张可重生成（≤3 轮），仍不过则程序化兜底 |
| AI 出图构图抖动（主体偏移 / 带多余元素） | 归一化脚本统一裁 alpha 包围盒 → 缩放 → 底边贴地居中；提示词固定"单主体、纯白底、无阴影、无文字" |
| `gl_compatibility` 的 2D 灯光不生效 | 回退：灯光烘焙进地面图 + CanvasModulate 夜色 |
| 夜色过暗导致看不清角色/守卫 | 夜色起步值偏亮（0.70），实机截图调节；必要时给守卫加一圈微亮边缘 |
| 2x 素材导致体积上升 | 全部 PNG 预计 < 1.5MB，可接受 |
| `flip_h` 抖动 | 加速度阈值（如 |vx| > 8 px/s 才翻），并做 0.15s 滞回 |

## 11. 实施批次

1. **角色**：7 张（6 村民 + 守卫）→ 验证风格一致与锚点不变量。
2. **道具**：10 张 → 逐个确认可辨认。
3. **地面**：草地 / 土路贴图 + 烘焙 `map_ground.png` + 相机钳制 → 消除黑虚空。
4. **代码与契约**：自动锚定、`flip_h`、灯光、`CanvasModulate` → 测试契约更新 → 全量测试 → 前后对比截图。

每批次结束提交一次，不 push。
