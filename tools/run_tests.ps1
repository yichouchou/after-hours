<#
.SYNOPSIS
    After Hours — 统一测试入口：先导入资源，再逐个跑 headless 测试。

.DESCRIPTION
    为什么需要这个脚本：
    本仓库的 .gitignore 忽略了 .godot/ 与 *.import，所以任何干净检出里都不存在
    PNG 的导入产物。而 Global Constraints 规定的测试命令
        godot --headless --path <proj> --script res://tools/test_<name>.gd
    不含 --import，直接跑会让 load() 返回 null、并抛出引擎 ERROR
    ("No loader found for resource: ...")，把"没导入"误报成"测试失败"。

    本脚本把规范命令固化成两步链：
        1) godot --headless --path <repo> --import
        2) 对每个 tools/test_*.gd 跑
           godot --headless --path <repo> --quit-after 600 --script res://tools/<name>

    判定通过 = 退出码 0 且输出含 "TEST PASSED"（两者都要看：
    --quit-after 兜底退出时退出码也是 0，单看退出码会把失败误判成通过）。
    全部跑完打印汇总；任一失败则整体退出码非 0。

    仓库根由 $PSScriptRoot 推导，不硬编码绝对路径，可在任意工作目录下调用。

    执行策略：本机默认 Restricted，直接 `& tools\run_tests.ps1` 会被拦。
    用进程级绕过（不修改机器设置）：
        powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1

.PARAMETER Godot
    Godot 可执行文件路径。留空时依次尝试：
      1) 环境变量 AFTER_HOURS_GODOT
      2) PATH 上的 godot / godot4
      3) 本机默认安装位置

.PARAMETER QuitAfter
    传给 Godot 的 --quit-after 帧数（默认 600，约 10 秒），防止测试脚本挂起。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1 -Godot 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe'
#>
[CmdletBinding()]
param(
    [string]$Godot = "",
    [int]$QuitAfter = 600
)

# 原生命令的 stderr 要用 2>&1 合并捕获；ErrorActionPreference 不能是 Stop，
# 否则 Godot 写到 stderr 的任何一行都会把脚本打断。
$ErrorActionPreference = 'Continue'

# 仓库根由脚本自身位置推导（tools/ 的上一级），不硬编码绝对路径。
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TestDir = Join-Path $RepoRoot 'tools'


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

    $fallback = 'D:\Godot\Godot_v4.7.2-stable_win64_console.exe'
    if (Test-Path -LiteralPath $fallback) {
        return $fallback
    }

    throw "找不到 Godot 可执行文件。请用 -Godot <路径> 指定，或设置环境变量 AFTER_HOURS_GODOT。"
}


function Invoke-Godot {
    param([string[]]$GodotArgs)

    $raw = & $script:GodotExe @GodotArgs 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
    # 去掉 ANSI 颜色/进度条转义序列，让日志可读（只影响终端显示，不影响判定）。
    # 注意：Windows PowerShell 5.1 不支持 `e 转义，必须用 [char]27 显式取 ESC。
    $esc = [string][char]27
    $text = ($raw -join "`n") -replace ($esc + '\[[0-9;?]*[A-Za-z]'), ''
    return @{ ExitCode = $code; Output = $text }
}


try {
    $script:GodotExe = Resolve-GodotExe -Candidate $Godot
} catch {
    Write-Host "[run_tests] $($_.Exception.Message)"
    exit 1
}

Write-Host "仓库根 : $RepoRoot"
Write-Host "Godot  : $script:GodotExe"
Write-Host ""

# ---------------------------------------------------------------- 步骤 1：导入
Write-Host "=== [1/2] 导入资源 (--import) ==="
$import = Invoke-Godot @('--headless', '--path', $RepoRoot, '--import')
Write-Host $import.Output
Write-Host ("--import 退出码 : {0}" -f $import.ExitCode)
Write-Host ""

if ($import.ExitCode -ne 0) {
    Write-Host "[run_tests] 导入失败（退出码 $($import.ExitCode)），不再跑测试。"
    exit 1
}

# ---------------------------------------------------------------- 步骤 2：测试
$tests = @(Get-ChildItem -Path $TestDir -Filter 'test_*.gd' -File | Sort-Object Name)
if ($tests.Count -eq 0) {
    Write-Host "[run_tests] tools/ 下没有找到 test_*.gd"
    exit 1
}

Write-Host ("=== [2/2] 逐个跑测试 (--quit-after {0}) ===" -f $QuitAfter)

$results = @()
foreach ($t in $tests) {
    $res = "res://tools/$($t.Name)"
    Write-Host ""
    Write-Host "--- $($t.Name) ---"
    $r = Invoke-Godot @('--headless', '--path', $RepoRoot, '--quit-after', "$QuitAfter", '--script', $res)
    Write-Host $r.Output
    $hasPassed = $r.Output -match 'TEST PASSED'
    $hasFailed = $r.Output -match 'TEST FAILED'
    # 判定通过 = 退出码 0 且输出含 TEST PASSED（两个信号都要看）
    $ok = ($r.ExitCode -eq 0) -and $hasPassed -and (-not $hasFailed)
    $results += [pscustomobject]@{ Name = $t.Name; ExitCode = $r.ExitCode; Passed = $ok }
    Write-Host ("[{0}] {1}  退出码={2}  含TEST PASSED={3}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $t.Name, $r.ExitCode, $hasPassed)
}

# ---------------------------------------------------------------- 汇总
Write-Host ""
Write-Host "=== 汇总 ==="
foreach ($r in $results) {
    Write-Host ("  {0,-26} 退出码={1}  {2}" -f $r.Name, $r.ExitCode, $(if ($r.Passed) { 'PASS' } else { 'FAIL' }))
}
$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ("共 {0} 个测试：{1} 个通过，{2} 个失败" -f $results.Count, ($results.Count - $failed.Count), $failed.Count)

if ($failed.Count -gt 0) {
    Write-Host "[run_tests] 存在失败测试，整体退出码 1。"
    exit 1
}

Write-Host "[run_tests] 全部通过。"
exit 0
