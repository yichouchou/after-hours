<#
.SYNOPSIS
    After Hours — 独立启动游戏窗口（不走编辑器 F5）。

.DESCRIPTION
    为什么需要这个脚本：

    编辑器里按 F5 跑起来的是**编辑器托管的嵌入式游戏窗口**（标题 "After Hours (DEBUG)"，
    带一条编辑器工具栏）。实测那条路径下，键盘事件**不可靠地转发给游戏**：
    逐键测试只有第一个按键生效，之后的按键全部丢失（画面不动），表现就是
    "走几步就动不了了"。换成**独立进程**启动的普通 Godot 窗口，不经过编辑器转发，
    8 个键里 7 个正常（静止噪声基线 0，按键即有可见变化）。

    本脚本只做一件事：用 --path <仓库根> 启动一个独立的游戏进程。

    ★ 窗口标题仍然带 "(DEBUG)"：那是 Godot 调试构建的默认标题，与是否走 F5 无关。
      判断"是不是独立运行"看**进程**：独立运行会多出一个自己的 Godot 进程，
      编辑器进程不受影响、Debugger 面板也不会接管这个窗口。

    仓库根由 $PSScriptRoot 推导，不硬编码绝对路径，可在任意工作目录下调用。

    操作流程：
      1) 点「创建房间」   —— 房主（单机游戏也走这一步）
      2) 点「开始这一夜」 —— 进入对局
    ★ 不要点「加入房间」：单机没有房主，8 秒后会自动退回大厅，
      看起来就像"点了没反应"。

    联机（两个窗口）：
      1) 窗口 A：点「创建房间」
      2) 窗口 B：点「加入房间」（固定连 127.0.0.1:28000）
      3) 两边都就位后，窗口 A 点「开始这一夜」

.PARAMETER Godot
    Godot 可执行文件路径。留空时依次尝试：
      1) 环境变量 AFTER_HOURS_GODOT
      2) PATH 上的 godot / godot4
      3) 本机默认安装位置（优先 GUI 版，其次 console 版）

.PARAMETER Second
    启动**第二个**实例（联机时当客户端用）。固定端口 28000，同一时刻只能有一个房主。

.PARAMETER Import
    启动前先跑一次 --import。仅在首次克隆、.godot/ 不存在（素材没导入）时才需要。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\run_game.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\run_game.ps1 -Second

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\run_game.ps1 -Import
#>
[CmdletBinding()]
param(
    [string]$Godot = "",
    [switch]$Second,
    [switch]$Import
)

# Godot 自己会往 stderr 写日志，ErrorActionPreference 不能是 Stop，否则脚本会被打断。
$ErrorActionPreference = 'Continue'

# 仓库根由脚本自身位置推导（tools/ 的上一级），不硬编码绝对路径。
$RepoRoot = Split-Path -Parent $PSScriptRoot


function Resolve-GodotExe {
    param([string]$Candidate)

    if (-not [string]::IsNullOrEmpty($Candidate)) {
        if (-not (Test-Path -LiteralPath $Candidate)) {
            throw "找不到 Godot 可执行文件：$Candidate"
        }
        return (Resolve-Path -LiteralPath $Candidate).Path
    }

    if (-not [string]::IsNullOrEmpty($env:AFTER_HOURS_GODOT)) {
        if (-not (Test-Path -LiteralPath $env:AFTER_HOURS_GODOT)) {
            throw "环境变量 AFTER_HOURS_GODOT 指向的文件不存在：$($env:AFTER_HOURS_GODOT)"
        }
        return (Resolve-Path -LiteralPath $env:AFTER_HOURS_GODOT).Path
    }

    foreach ($name in @('godot', 'godot4')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            return $cmd.Source
        }
    }

    # 优先 GUI 版（不弹控制台窗口）；找不到再退到 console 版。
    $fallbacks = @(
        'D:\Godot\Godot_v4.7.2-stable_win64.exe',
        'D:\Godot\Godot_v4.7.2-stable_win64_console.exe'
    )
    foreach ($f in $fallbacks) {
        if (Test-Path -LiteralPath $f) {
            return $f
        }
    }

    throw "找不到 Godot 可执行文件。请用 -Godot <路径> 指定，或设置环境变量 AFTER_HOURS_GODOT。"
}


try {
    $script:GodotExe = Resolve-GodotExe -Candidate $Godot
} catch {
    Write-Host "[run_game] $($_.Exception.Message)"
    exit 1
}

Write-Host "仓库根 : $RepoRoot"
Write-Host "Godot  : $script:GodotExe"
Write-Host ""

# ---------------------------------------------------------------- 导入（可选）
if ($Import) {
    Write-Host "=== 导入资源 (--import) ==="
    & $script:GodotExe --headless --path $RepoRoot --import 2>&1 | ForEach-Object { $_.ToString() }
    Write-Host ("--import 退出码 : {0}" -f $LASTEXITCODE)
    Write-Host ""
}

# ---------------------------------------------------------------- 启动
# 用 Start-Process 而不是 &：游戏是长驻窗口，直接调用会占住当前终端。
$proc = Start-Process -FilePath $script:GodotExe -ArgumentList @('--path', $RepoRoot) -PassThru

$role = if ($Second) { '第二个实例（客户端：点「加入房间」）' } else { '房主 / 单机（点「创建房间」→ 点「开始这一夜」）' }
Write-Host ("=== 已启动独立游戏进程 ===")
Write-Host ("  pid  : {0}" -f $proc.Id)
Write-Host ("  窗口 : After Hours (DEBUG)")
Write-Host ("  角色 : {0}" -f $role)
Write-Host ""
Write-Host "下一步：在游戏窗口里点按钮；进对局后**先在窗口里点一下鼠标**，再按方向键。"
Write-Host "关掉这个窗口即可结束进程。"

exit 0
