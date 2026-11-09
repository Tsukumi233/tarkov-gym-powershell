[CmdletBinding()]
param(
    [int[]]$DelaysMs = @(2500, 1600, 1700, 1800, 1830, 1760, 1800, 1720, 1735, 1655, 1575, 1530, 1535, 1500, 1485),
    [ValidateRange(1, 1000)]
    [int]$ClickDurationMs = 30,
    [switch]$StartNow,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($DelaysMs.Count -eq 0) {
    throw '至少需要一段点击延迟。'
}
foreach ($delay in $DelaysMs) {
    if ($delay -lt 0 -or $delay -gt 60000) {
        throw '每段延迟必须在 0 到 60000 毫秒之间。'
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class TarkovGymNative
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern void mouse_event(
        uint flags,
        uint x,
        uint y,
        uint data,
        UIntPtr extraInfo
    );
}
'@

$VK_F = 0x46
$VK_F9 = 0x78
$VK_F10 = 0x79
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTFLEFTUP = 0x0004
$script:SequenceClock = $null

function Test-KeyDown {
    param([int]$VirtualKey)
    return ([TarkovGymNative]::GetAsyncKeyState($VirtualKey) -band 0x8000) -ne 0
}

function Stop-ForExitKey {
    if (Test-KeyDown $VK_F10) {
        throw '已按 F10 停止。'
    }
}

function Wait-UntilSequenceTime {
    param([double]$TargetMs)

    while ($true) {
        Stop-ForExitKey
        $remaining = $TargetMs - $script:SequenceClock.Elapsed.TotalMilliseconds
        if ($remaining -le 0) {
            return
        }
        if ($remaining -gt 10) {
            Start-Sleep -Milliseconds 10
        }
        elseif ($remaining -gt 2) {
            Start-Sleep -Milliseconds 1
        }
        else {
            [System.Threading.Thread]::SpinWait(1000)
        }
    }
}

function Send-LeftClick {
    param([int]$Number)

    if ($DryRun) {
        Write-Host ("[模拟] 第 {0}/{1} 次左键点击，计划时刻 {2:N0} ms，实际时刻 {3:N0} ms" -f `
            $Number, $DelaysMs.Count, $script:TargetMs, $script:SequenceClock.Elapsed.TotalMilliseconds)
        return
    }

    [TarkovGymNative]::mouse_event($MOUSEEVENTFLEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    try {
        $releaseAt = $script:SequenceClock.Elapsed.TotalMilliseconds + $ClickDurationMs
        Wait-UntilSequenceTime $releaseAt
    }
    finally {
        [TarkovGymNative]::mouse_event($MOUSEEVENTFLEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    }

    Write-Host ("第 {0}/{1} 次左键点击，计划时刻 {2:N0} ms，实际时刻 {3:N0} ms" -f `
        $Number, $DelaysMs.Count, $script:TargetMs, $script:SequenceClock.Elapsed.TotalMilliseconds)
}

function Invoke-GymSequence {
    $script:SequenceClock = [System.Diagnostics.Stopwatch]::StartNew()
    $script:TargetMs = 0.0

    try {
        for ($index = 0; $index -lt $DelaysMs.Count; $index++) {
            $script:TargetMs += $DelaysMs[$index]
            Wait-UntilSequenceTime $script:TargetMs
            Send-LeftClick ($index + 1)
        }
        Write-Host ("已完成 {0} 次点击，自动停止。" -f $DelaysMs.Count) -ForegroundColor Green
    }
    finally {
        if (-not $DryRun) {
            [TarkovGymNative]::mouse_event($MOUSEEVENTFLEFTUP, 0, 0, 0, [UIntPtr]::Zero)
        }
        if ($null -ne $script:SequenceClock) {
            $script:SequenceClock.Stop()
        }
    }
}

Write-Host '塔科夫健身房固定时序点击 - PowerShell 版' -ForegroundColor Cyan
Write-Host '注意：游戏自动化可能违反游戏规则，账号风险由使用者承担。' -ForegroundColor Yellow
Write-Host ("点击次数：{0}；总时序：{1:N0} ms；按键时长：{2} ms" -f `
    $DelaysMs.Count, (($DelaysMs | Measure-Object -Sum).Sum), $ClickDurationMs)

if ($DryRun) {
    Write-Host 'DryRun 已启用，不会发送真实鼠标输入。' -ForegroundColor Yellow
}
else {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warning '如果游戏以管理员身份运行，请同样用管理员身份打开 PowerShell。'
    }
}

if ($StartNow) {
    Invoke-GymSequence
    return
}

Write-Host 'F9：待命/取消待命；待命后在器材前按 F：开始；F10：随时退出。'
Write-Host '请先将鼠标放在游戏窗口内，不要移动到其他窗口。'

$armed = $false
$f9WasDown = Test-KeyDown $VK_F9
$fWasDown = Test-KeyDown $VK_F

try {
    while ($true) {
        if (Test-KeyDown $VK_F10) {
            Write-Host '已退出。'
            break
        }

        $f9Down = Test-KeyDown $VK_F9
        if ($f9Down -and -not $f9WasDown) {
            $armed = -not $armed
            if ($armed) {
                Write-Host '已待命：请在器材前按 F，点击时序以这次 F 键为起点。' -ForegroundColor Green
            }
            else {
                Write-Host '已取消待命。' -ForegroundColor Yellow
            }
        }

        $fDown = Test-KeyDown $VK_F
        if ($armed -and $fDown -and -not $fWasDown) {
            $armed = $false
            Invoke-GymSequence
            Write-Host '可按 F9 再次待命，或按 F10 退出。'
        }

        $f9WasDown = $f9Down
        $fWasDown = $fDown
        Start-Sleep -Milliseconds 15
    }
}
finally {
    if (-not $DryRun) {
        [TarkovGymNative]::mouse_event($MOUSEEVENTFLEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    }
}
