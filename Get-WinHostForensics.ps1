<#
.SYNOPSIS
    Windows 主机信息收集器 —— 按「系统事件 → 内核信息 → 运行服务 → 服务日志」顺序采集，供 AI 分析

.DESCRIPTION
    采集顺序（也是输出目录的编号顺序）：
      01_system_events   系统事件：System / Application / Setup / HardwareEvents
                         （含一份「关键诊断事件ID」清单，这些事件多为 Information 级，
                           例如 7045 新装服务、5858 WMI 操作失败、12/13 系统启动与关机）
      02_kernel          内核/硬件相关事件通道 + 内核驱动清单
                         + 崩溃转储与实时内核报告清单 + 内核与启动状态 + 防火墙丢包记录
      03_services        运行服务清单：运行中的服务及其实例信息（PID/映像路径/启动时间）
                         + 全部服务（含启动类型/状态/账户）+ 采集时刻进程清单
      04_service_logs    运行服务的日志：为每个运行服务匹配它自己的事件日志通道
                         （按服务名/显示名/映像文件名 去匹配 通道名 与 提供程序名），
                         把这些通道在时间窗口内的事件单独存一份，并给出服务↔日志映射表
      故障画像           All（默认）额外覆盖蓝屏转储/WER、黑屏显示/会话、服务失败恢复策略；
                         也可用 -IncidentProfile 只启用某一类画像。

    设计原则：
      - **只收集，不解读**。不做根因判断、不做风险定级、不给结论。
      - **保留原文**。事件消息不改写、不聚合、不折叠重复；单条上限默认 4000 字符。
      - **窗口聚焦**。给一个时间范围，窗口内取全；窗口外只做计数。
      - **单文件自包含**，只读，非管理员也能跑（拿不到的数据源如实记录）。

.PARAMETER Start / End / At / WindowMinutes / HoursBack
    时间范围。都不给时默认「最近 24 小时」。

.PARAMETER LeadMinutes
    可选前导期（分钟）：窗口前这段也一并采集全文，并在事件中标记 scope=lead。默认 0。

.PARAMETER BaselineHours
    基线期（小时）：只统计条数、不保存消息。0 = 关闭。默认 0。

.PARAMETER MaxMessageLength
    单条消息保留上限（字符）。默认 4000；设 0 表示不限制。

.PARAMETER MaxEventsPerLog
    每个日志/通道条数上限。默认 0（不限制）。设为正数时触顶会在 REPORT.md 和事件统计中标注。

.PARAMETER AllLevels
    兼容参数。当前默认已采集全部标准级别（0-5）。

.PARAMETER ErrorsOnly
    仅采集 Critical/Error/Warning（1-3 级）及显式诊断事件 ID。

.PARAMETER IncludeXml
    额外保存每条事件的完整 XML。

.PARAMETER IncludeSecurity
    采集安全日志（需管理员）。

.PARAMETER IncidentProfile
    故障画像：Core / BlueScreen / BlackScreen / ServiceDown / All。默认 All。

.PARAMETER IncludeCrashDumps
    复制窗口内或最近修改的 Minidump/LiveKernelReports 小型转储（大 MEMORY.DMP 只列清单）。

.PARAMETER ExtraLogs
    额外采集的日志/通道名（数组）。

.PARAMETER Elevate / NoZip / OutputRoot / Help
    提权重启 / 不打包 / 输出根目录 / 显示帮助。

.EXAMPLE
    # 现场快速收集：最近 24 小时
    powershell -ExecutionPolicy Bypass -File .\Get-WinHostForensics.ps1

.EXAMPLE
    # 指定时间段
    powershell -ExecutionPolicy Bypass -File .\Get-WinHostForensics.ps1 -Start '2026-09-24 15:00' -End '2026-09-24 15:20'

.EXAMPLE
    # 提权 + 安全日志 + 输出到 U 盘
    powershell -ExecutionPolicy Bypass -File .\Get-WinHostForensics.ps1 -Start '<起>' -End '<止>' -IncludeSecurity -Elevate -OutputRoot E:\

.NOTES
    版本 4.2.0  |  只读  |  单文件  |  Windows PowerShell 5.1 / PowerShell 7
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Help,
    [datetime]$Start = [datetime]::MinValue,
    [datetime]$End = [datetime]::MinValue,
    [datetime]$At = [datetime]::MinValue,
    [int]$WindowMinutes = 30,
    [int]$HoursBack = 24,
    [int]$LeadMinutes = 0,
    [int]$BaselineHours = 0,
    [int]$MaxMessageLength = 4000,
    [int]$MaxEventsPerLog = 0,
    [switch]$AllLevels,
    [switch]$ErrorsOnly,
    [switch]$IncludeXml,
    [string[]]$ExtraLogs = @(),
    [switch]$IncludeSecurity,
    [ValidateSet('Core','BlueScreen','BlackScreen','ServiceDown','All')]
    [string]$IncidentProfile = 'All',
    [switch]$IncludeCrashDumps,
    [switch]$Elevate,
    [switch]$NoZip,
    [string]$OutputRoot = ''
)

$ScriptVersion = '4.2.0'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$_off = (Get-TimeZone).BaseUtcOffset
$script:UtcOffsetText = ('{0}{1:00}:{2:00}' -f $(if ($_off.Ticks -lt 0) { '-' } else { '+' }), [math]::Abs($_off.Hours), [math]::Abs($_off.Minutes))

# =====================================================================
# 帮助
# =====================================================================
function Show-Usage {
    $lines = @(
        '',
        '==================================================================',
        (' Windows 主机信息收集器（单文件版） v{0}' -f $ScriptVersion),
        '==================================================================',
        '',
        ' 采集顺序（也是输出目录编号）：',
        '   01_system_events  系统事件（System/Application/Setup/HardwareEvents + 关键诊断事件ID）',
        '   02_kernel         内核/硬件相关通道 + 内核驱动 + 崩溃转储 + 启动状态 + 防火墙丢包',
        '   03_services       运行服务清单（运行中服务 + 实例信息 + 全部服务 + 进程清单）',
        '   04_service_logs   运行服务自己的日志（按服务名匹配通道，单独成文件 + 映射表）',
        '',
        ' 只收集、不解读：不做根因判断、不做风险定级、不给结论。只读，不改系统。',
        '',
        ' ---------------- 时间范围（都不给则用「最近 24 小时」）----------------',
        '  -Start <时间>          窗口起点，如 -Start "2026-09-24 15:00"',
        '  -End   <时间>          窗口终点；只给 -Start 时按 -WindowMinutes 向后推算',
        '  -At    <时间>          窗口 = [At - WindowMinutes, At]',
        '  -WindowMinutes <n>     窗口长度（分钟）。默认 30',
        '  -HoursBack <n>         不给时间范围时往前采集多少小时。默认 24',
        '',
        ' ---------------- 采集范围 ----------------',
        '  -LeadMinutes <n>       可选前导期（分钟），事件会标记 scope=lead。默认 0（严格窗口）',
        '  -BaselineHours <n>     可选基线期（小时）：只统计条数不存消息。默认 0，0 = 关闭',
        '  -MaxMessageLength <n>  单条消息保留上限（字符）。默认 4000，0 = 不限',
        '  -MaxEventsPerLog <n>   每个日志条数上限。默认 0（不限制）',
        '  -AllLevels             兼容参数；默认已采集全部标准级别（0-5）',
        '  -ErrorsOnly            仅采集 1-3 级 + 关键诊断事件ID',
        '  -IncludeXml            额外保存每条事件的完整 XML',
        '  -ExtraLogs <日志名>    额外采集的日志（数组）',
        '  -IncludeSecurity       采集安全日志（需管理员）',
        '  -IncidentProfile <p>   故障画像：Core/BlueScreen/BlackScreen/ServiceDown/All，默认 All',
        '  -IncludeCrashDumps     复制小型转储；大 MEMORY.DMP 只列清单',
        '',
        ' ---------------- 运行方式 ----------------',
        '  -Elevate               非管理员时自动弹 UAC 提权重启（推荐）',
        '  -NoZip                 不生成 zip 压缩包',
        '  -OutputRoot <路径>     输出根目录，默认脚本所在目录的 out\',
        '  -Help                  显示本帮助',
        '',
        ' ---------------- 示例 ----------------',
        '  powershell -ExecutionPolicy Bypass -File .\Get-WinHostForensics.ps1',
        '  powershell -ExecutionPolicy Bypass -File .\Get-WinHostForensics.ps1 -Start "2026-09-24 15:00" -End "2026-09-24 15:20"',
        '  powershell -ExecutionPolicy Bypass -File .\Get-WinHostForensics.ps1 -HoursBack 4 -AllLevels -IncludeXml',
        '',
        ' 参数完整帮助：Get-Help .\Get-WinHostForensics.ps1 -Full',
        ''
    )
    foreach ($l in $lines) { Write-Host $l }
}
if ($Help) { Show-Usage; exit 0 }

# =====================================================================
# 0. 时间窗口
# =====================================================================
$script:Now = Get-Date
if ($LeadMinutes -lt 0) { Write-Host '错误：LeadMinutes 不能为负数。' -ForegroundColor Red; exit 2 }
if ($BaselineHours -lt 0) { Write-Host '错误：BaselineHours 不能为负数。' -ForegroundColor Red; exit 2 }
if ($MaxMessageLength -lt 0) { Write-Host '错误：MaxMessageLength 不能为负数。' -ForegroundColor Red; exit 2 }
if ($MaxEventsPerLog -lt 0) { Write-Host '错误：MaxEventsPerLog 不能为负数。' -ForegroundColor Red; exit 2 }
$hasStart = ($Start -gt [datetime]::MinValue)
$hasEnd = ($End -gt [datetime]::MinValue)
$hasAt = ($At -gt [datetime]::MinValue)
if ($hasEnd -and -not $hasStart) { Write-Host '错误：End 必须和 Start 一起使用。' -ForegroundColor Red; exit 2 }
if (($hasAt -or ($hasStart -and -not $hasEnd)) -and $WindowMinutes -le 0) { Write-Host '错误：WindowMinutes 必须大于 0。' -ForegroundColor Red; exit 2 }
if (-not $hasStart -and -not $hasAt -and $HoursBack -le 0) { Write-Host '错误：HoursBack 必须大于 0。' -ForegroundColor Red; exit 2 }
if ($hasStart) {
    $winStart = $Start
    if ($hasEnd) { $winEnd = $End } else { $winEnd = $Start.AddMinutes($WindowMinutes) }
    $windowSource = 'user-provided (Start/End)'
} elseif ($hasAt) {
    $winStart = $At.AddMinutes(-$WindowMinutes)
    $winEnd = $At
    $windowSource = 'user-provided (At - WindowMinutes ~ At)'
} else {
    $winStart = $script:Now.AddHours(-$HoursBack)
    $winEnd = $script:Now
    $windowSource = ('default (最近 {0} 小时；可用 -Start/-End 或 -At 指定)' -f $HoursBack)
}
if ($winEnd -gt $script:Now) { $winEnd = $script:Now }
if ($winEnd -le $winStart) { Write-Host '错误：End 必须晚于 Start，且不能在当前时间之后。' -ForegroundColor Red; exit 2 }
$leadStart = $winStart.AddMinutes(-$LeadMinutes)
$baseStart = $leadStart.AddHours(-$BaselineHours)
$winMinutes = [math]::Round(($winEnd - $winStart).TotalMinutes, 1)
$leadMinutes = [math]::Round(($winStart - $leadStart).TotalMinutes, 1)
$includeBlueScreen = ($IncidentProfile -in @('All','BlueScreen'))
$includeBlackScreen = ($IncidentProfile -in @('All','BlackScreen'))
$includeServiceDown = ($IncidentProfile -in @('All','ServiceDown'))

# =====================================================================
# 1. 基础工具
# =====================================================================
function Fmt-DateSafe { param($v) if ($null -eq $v) { return '' } try { return ([datetime]$v).ToString('yyyy-MM-dd HH:mm:ss.fff zzz') } catch { return [string]$v } }
function Fmt-DateShort { param($v) if ($null -eq $v) { return '' } try { return ([datetime]$v).ToString('yyyy-MM-dd HH:mm:ss') } catch { return [string]$v } }
function Fmt-UtcSafe { param($v) if ($null -eq $v) { return '' } try { return ([datetime]$v).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z' } catch { return '' } }
function Compact-Text {
    param([string]$Text, [int]$Max = 300)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = ($Text -replace '\r?\n', ' '); $t = ($t -replace '\s{2,}', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + ' ...[截断]' }
    return $t
}
function Limit-Text {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Max -le 0 -or $Text.Length -le $Max) { return $Text }
    return ($Text.Substring(0, $Max) + ("`r`n...[本条消息超过 {0} 字符已截断；可用 -MaxMessageLength 调大]..." -f $Max))
}

# JSON 安全输出：Windows PowerShell 5.1 的 ConvertTo-Json 会连带序列化 Get-Content 字符串的
# ETS 附加成员（进入提供程序对象图 → 无界递归 → 卡死），因此先规范化为纯 .NET 值。
function ConvertTo-PlainValue {
    param($Value, [int]$Depth = 0, [int]$MaxDepth = 8)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [char]) { return [string]$Value }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]) { return $Value }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $Value }
    if ($Value -is [datetime]) { return (Fmt-DateSafe $Value) }
    if ($Value -is [datetimeoffset]) { return $Value.ToString('yyyy-MM-dd HH:mm:ss.fff zzz') }
    if ($Value -is [timespan]) { return $Value.ToString() }
    if ($Value -is [guid]) { return [string]$Value }
    if ($Value -is [enum]) { return [string]$Value }
    if ($Depth -ge $MaxDepth) { return ('<已达序列化最大深度 {0}>' -f $MaxDepth) }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in @($Value.Keys)) { $o[[string]$k] = ConvertTo-PlainValue -Value $Value[$k] -Depth ($Depth + 1) -MaxDepth $MaxDepth }
        return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $a = New-Object System.Collections.ArrayList
        foreach ($it in $Value) { [void]$a.Add((ConvertTo-PlainValue -Value $it -Depth ($Depth + 1) -MaxDepth $MaxDepth)) }
        return , ($a.ToArray())
    }
    $props = @()
    try { $props = @($Value.PSObject.Properties) } catch { $props = @() }
    if ($props.Count -gt 0) {
        $o2 = [ordered]@{}
        foreach ($p in $props) {
            $mt = ''
            try { $mt = [string]$p.MemberType } catch { $mt = '' }
            if ($mt -ne 'NoteProperty' -and $mt -ne 'Property' -and $mt -ne 'AliasProperty') { continue }
            $pv = $null
            try { $pv = $p.Value } catch { $pv = $null }
            $o2[[string]$p.Name] = ConvertTo-PlainValue -Value $pv -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
        return $o2
    }
    return [string]$Value
}
$script:JsonUnescapeRegex = New-Object System.Text.RegularExpressions.Regex '\\u([0-9a-fA-F]{4})'
function ConvertFrom-UnicodeEscape {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text.IndexOf('\u') -lt 0) { return $Text }
    return ($script:JsonUnescapeRegex.Replace($Text, {
                param($m)
                $code = [Convert]::ToInt32($m.Groups[1].Value, 16)
                if ($code -lt 32 -or $code -eq 34 -or $code -eq 92) { return $m.Value }
                return ([string][char]$code)
            }))
}
function ConvertTo-PrettyJson {
    param($Object, [int]$Depth = 6)
    $plain = ConvertTo-PlainValue -Value $Object -Depth 0 -MaxDepth $Depth
    if ($null -eq $plain) { return 'null' }
    if ($plain -is [array] -and @($plain).Count -eq 0) { return '[]' }
    $json = ConvertTo-Json -InputObject $plain -Depth $Depth
    if ($null -eq $json) { return 'null' }
    return (ConvertFrom-UnicodeEscape $json)
}
function ConvertTo-CompactJson {
    param($Object, [int]$Depth = 6)
    $plain = ConvertTo-PlainValue -Value $Object -Depth 0 -MaxDepth $Depth
    if ($null -eq $plain) { return 'null' }
    if ($plain -is [array] -and @($plain).Count -eq 0) { return '[]' }
    $json = ConvertTo-Json -InputObject $plain -Depth $Depth -Compress
    if ($null -eq $json) { return 'null' }
    return (ConvertFrom-UnicodeEscape $json)
}
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Write-TextFile { param([string]$Path, [string]$Text) $dir = Split-Path -Parent $Path; if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }; [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom) }
function Write-JsonFile { param([string]$Path, $Object, [int]$Depth = 6) Write-TextFile -Path $Path -Text (ConvertTo-PrettyJson -Object $Object -Depth $Depth) }
function ConvertTo-JsonString {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '""' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        switch ($c) {
            34 { [void]$sb.Append('\"') }
            92 { [void]$sb.Append('\\') }
            8 { [void]$sb.Append('\b') }
            12 { [void]$sb.Append('\f') }
            10 { [void]$sb.Append('\n') }
            13 { [void]$sb.Append('\r') }
            9 { [void]$sb.Append('\t') }
            default { if ($c -lt 32) { [void]$sb.Append('\u' + $c.ToString('x4')) } else { [void]$sb.Append($ch) } }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
function Get-SafeFileName { param([string]$Name) return ($Name -replace '[\\/:*?"<>|]', '-') }
function Get-FileSha256Safe {
    param([string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return '' }
}

function Get-EventLevelFilter {
    if ($ErrorsOnly) { return @(1, 2, 3) }
    # 0=LogAlways，1-5=Critical/Error/Warning/Information/Verbose。
    return @(0, 1, 2, 3, 4, 5)
}

$script:Sources = New-Object System.Collections.ArrayList
function Add-Source { param([string]$Name, [string]$Status, [string]$Detail = '', [int]$Count = -1) $null = $script:Sources.Add([pscustomobject]@{ source = $Name; status = $Status; count = $Count; detail = (Compact-Text $Detail 200) }) }

function Get-WinEventSafe {
    param([string]$LogName, [datetime]$From, [datetime]$To, [int[]]$Id, [int[]]$Level, [int]$MaxEvents = 0)
    $idList = @()
    if ($null -ne $Id -and @($Id).Count -gt 0) { $idList = @($Id) }
    if ($idList.Count -gt 12) {
        $merged = New-Object System.Collections.ArrayList
        $seen = @{}
        $fail = 0
        $err = ''
        for ($i = 0; $i -lt $idList.Count; $i += 12) {
            $end = [math]::Min($i + 11, $idList.Count - 1)
            $sub = Get-WinEventSafe -LogName $LogName -From $From -To $To -Id @($idList[$i..$end]) -Level $Level -MaxEvents $MaxEvents
            if ($null -eq $sub -or -not $sub.ok) { $fail++; if ($sub) { $err = $sub.error }; continue }
            foreach ($ev in $sub.events) {
                $key = '{0}|{1}' -f $ev.LogName, $ev.RecordId
                if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [void]$merged.Add($ev) }
            }
        }
        if ($fail -gt 0 -and $merged.Count -eq 0) { return @{ ok = $false; events = @(); error = $(if ($err) { $err } else { "分批查询全部失败（$fail 个分片）" }); capped = $false } }
        return @{ ok = $true; events = @($merged); error = $(if ($fail -gt 0) { "部分分片失败($fail)" } else { '' }); capped = $false }
    }
    $f = @{ LogName = $LogName; StartTime = $From; EndTime = $To }
    if ($idList.Count -gt 0) { $f['Id'] = $idList }
    if ($null -ne $Level -and @($Level).Count -gt 0) { $f['Level'] = @($Level) }
    $p = @{ FilterHashtable = $f; ErrorAction = 'Stop' }
    if ($MaxEvents -gt 0) { $p['MaxEvents'] = $MaxEvents }
    try {
        $ev = @(Get-WinEvent @p)
        return @{ ok = $true; events = $ev; error = ''; capped = ($MaxEvents -gt 0 -and $ev.Count -ge $MaxEvents) }
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'No events were found|没有找到|未找到') { return @{ ok = $true; events = @(); error = ''; capped = $false } }
        return @{ ok = $false; events = @(); error = $m; capped = $false }
    }
}

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    $old = $null
    try { $old = [Console]::OutputEncoding } catch { }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::Default } catch { }
    $out = @()
    try {
        if ($Arguments -and @($Arguments).Count -gt 0) { $out = @(& $Command @Arguments 2>&1) } else { $out = @(& $Command 2>&1) }
    } catch { $out = @("命令执行失败: $($_.Exception.Message)") }
    finally { try { if ($null -ne $old) { [Console]::OutputEncoding = $old } } catch { } }
    return @($out | ForEach-Object { [string]$_ })
}

function Get-ErrStatus {
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return 'error' }
    if ($Message -match '拒绝访问|Access is denied|Access denied|Unauthorized|unauthorized|权限') { return 'denied' }
    if ($Message -match 'No events were found|没有找到|未找到') { return 'empty' }
    if ($Message -match '不存在|does not exist|There is not an event log|is disabled|已禁用') { return 'missing' }
    return 'error'
}

# =====================================================================
# 2. 运行环境与输出目录
# =====================================================================
$script:Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal($script:Identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $script:IsAdmin -and $Elevate) {
    Write-Host '[!] 正在请求以管理员身份重启（可采集安全日志等）...' -ForegroundColor Yellow
    $argList = New-Object System.Collections.ArrayList
    [void]$argList.Add('-NoProfile'); [void]$argList.Add('-ExecutionPolicy'); [void]$argList.Add('Bypass')
    [void]$argList.Add('-File'); [void]$argList.Add(('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'Elevate') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { [void]$argList.Add("-$k") } }
        else { [void]$argList.Add("-$k"); [void]$argList.Add(('"{0}"' -f $v)) }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList ($argList -join ' ') | Out-Null
        Write-Host '[√] 已提交提权请求，请在 UAC 窗口中确认。' -ForegroundColor Green
        exit 0
    } catch { Write-Host "[!] 提权失败：$($_.Exception.Message)，继续以当前权限采集。" -ForegroundColor Yellow }
    $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = (Get-Location).Path }
if ([string]::IsNullOrEmpty($OutputRoot)) { $OutputRoot = Join-Path $scriptDir 'out' }
$hostLabel = $env:COMPUTERNAME
if ([string]::IsNullOrEmpty($hostLabel)) { $hostLabel = 'UNKNOWNHOST' }
$stamp = $script:Now.ToString('yyyyMMdd_HHmmss')
$runDir = Join-Path $OutputRoot ("WinHostForensics_{0}_{1}" -f $hostLabel, $stamp)
$dirSystemEvents = Join-Path $runDir '01_system_events'
$dirKernel = Join-Path $runDir '02_kernel'
$dirKernelEvents = Join-Path $dirKernel 'events'
$dirServices = Join-Path $runDir '03_services'
$dirServiceLogs = Join-Path $runDir '04_service_logs'
$dirState = Join-Path $runDir 'state'
$dirRaw = Join-Path $runDir 'raw'
foreach ($d in @($runDir, $dirSystemEvents, $dirKernel, $dirKernelEvents, $dirServices, $dirServiceLogs, $dirState, $dirRaw)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

Write-Host ''
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host (' Windows 主机信息收集器（单文件版） v{0}' -f $ScriptVersion) -ForegroundColor Cyan
Write-Host ' 采集顺序：01 系统事件 -> 02 内核信息 -> 03 运行服务 -> 04 服务日志' -ForegroundColor Cyan
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host (' 主机      : {0}  (管理员: {1})' -f $hostLabel, $script:IsAdmin)
Write-Host (' 采集期    : {0} ~ {1}  ({2} 分钟)' -f (Fmt-DateShort $winStart), (Fmt-DateShort $winEnd), $winMinutes) -ForegroundColor Yellow
Write-Host (' 前导期    : {0} ~ {1}  ({2} 分钟)' -f (Fmt-DateShort $leadStart), (Fmt-DateShort $winStart), $leadMinutes)
Write-Host (' 故障画像  : {0}' -f $IncidentProfile) -ForegroundColor Yellow
if ($BaselineHours -gt 0) { Write-Host (' 基线期    : {0} ~ {1}  ({2} 小时，只计数)' -f (Fmt-DateShort $baseStart), (Fmt-DateShort $leadStart), $BaselineHours) }
Write-Host (' 级别/上限 : {0} / 消息 {1} 字符 / 每日志 {2} 条（0=不限制）' -f $(if ($ErrorsOnly) { '1-3 级 + 关键诊断ID' } else { '全部标准级别 0-5' }), $MaxMessageLength, $MaxEventsPerLog)
Write-Host (' 输出目录  : {0}' -f $runDir)
Write-Host ''

# 事件写出：JSONL，一行一个事件，消息保留原文
$script:LogStats = New-Object System.Collections.ArrayList
$script:EventSetResults = @{}
$script:QueriedLogs = @{}
function Save-EventSet {
    param([string]$Stage, [string]$LogName, [string]$TargetDir, [int[]]$ExtraIds = @(), [string]$Note = '')
    $cacheKey = ('{0}|{1}' -f $TargetDir.ToLowerInvariant(), $LogName.ToLowerInvariant())
    if ($script:EventSetResults.ContainsKey($cacheKey)) { return $script:EventSetResults[$cacheKey] }
    $script:QueriedLogs[$LogName] = $true
    $pool = New-Object System.Collections.ArrayList
    $seenRec = @{}
    $errs = @()
    $capped = $false
    $ok = $false

    $levelFilter = @(Get-EventLevelFilter)
    $r1 = Get-WinEventSafe -LogName $LogName -From $leadStart -To $winEnd -Level $levelFilter -MaxEvents $MaxEventsPerLog
    if ($r1.ok) {
        $ok = $true
        foreach ($e in $r1.events) { if (-not $seenRec.ContainsKey($e.RecordId)) { $seenRec[$e.RecordId] = $true; [void]$pool.Add($e) } }
        if ($r1.capped) { $capped = $true }
    } else { $errs += $r1.error }

    if ($ErrorsOnly -and $ExtraIds.Count -gt 0) {
        $r2 = Get-WinEventSafe -LogName $LogName -From $leadStart -To $winEnd -Id $ExtraIds -MaxEvents $MaxEventsPerLog
        if ($r2.ok) {
            $ok = $true
            foreach ($e in $r2.events) { if (-not $seenRec.ContainsKey($e.RecordId)) { $seenRec[$e.RecordId] = $true; [void]$pool.Add($e) } }
            if ($r2.capped) { $capped = $true }
        } else { $errs += $r2.error }
    }

    if (-not $ok) {
        $failed = [pscustomobject]@{ ok = $false; log = $LogName; status = (Get-ErrStatus ($errs -join ' ; ')); count = 0; detail = ($errs -join ' ; '); file = '' }
        $script:EventSetResults[$cacheKey] = $failed
        return $failed
    }

    $events = @($pool | Where-Object { $_.TimeCreated -and $_.TimeCreated -ge $leadStart -and $_.TimeCreated -le $winEnd } | Sort-Object TimeCreated)
    if ($MaxEventsPerLog -gt 0 -and $events.Count -gt $MaxEventsPerLog) { $capped = $true; $events = @($events | Select-Object -First $MaxEventsPerLog) }

    $sb = New-Object System.Text.StringBuilder
    $inWindow = 0
    $inLead = 0
    foreach ($e in $events) {
        $msg = ''
        try { $msg = [string]$e.Message } catch { $msg = '' }
        $msg = Limit-Text -Text $msg -Max $MaxMessageLength
        $lvl = ''
        try { $lvl = [string]$e.LevelDisplayName } catch { }
        if (-not $lvl) { switch ($e.Level) { 0 { $lvl = 'LogAlways' } 1 { $lvl = 'Critical' } 2 { $lvl = 'Error' } 3 { $lvl = 'Warning' } 4 { $lvl = 'Information' } 5 { $lvl = 'Verbose' } default { $lvl = "Level$($e.Level)" } } }
        $uid = ''
        try { $uid = [string]$e.UserId } catch { $uid = '' }
        $task = ''
        try { $task = [string]$e.TaskDisplayName } catch { $task = '' }
        $propValues = New-Object System.Collections.ArrayList
        $propTextValues = New-Object System.Collections.ArrayList
        try {
            $i = 0
            foreach ($p in @($e.Properties)) {
                $value = [string]$p.Value
                [void]$propValues.Add([pscustomobject]@{ index = $i; value = $value })
                [void]$propTextValues.Add($value)
                $i++
            }
        } catch { }
        $propsOut = ($propTextValues -join ' | ')
        $propsJson = ConvertTo-CompactJson -Object @($propValues) -Depth 4
        $scope = 'window'
        if ($e.TimeCreated -lt $winStart) { $scope = 'lead'; $inLead++ } else { $inWindow++ }
        $opcode = ''
        try { $opcode = [string]$e.OpcodeDisplayName } catch { }
        $keywords = ''
        try { $keywords = (@($e.KeywordsDisplayNames) -join '; ') } catch { }
        $processId = $null
        try { if ($null -ne $e.ProcessId) { $processId = [int]$e.ProcessId } } catch { }
        $threadId = $null
        try { if ($null -ne $e.ThreadId) { $threadId = [int]$e.ThreadId } } catch { }
        $recordId = 0
        try { $recordId = [int64]$e.RecordId } catch { }
        $eventLevelId = 0
        try { if ($null -ne $e.Level) { $eventLevelId = [int]$e.Level } } catch { }

        $fields = New-Object System.Collections.ArrayList
        [void]$fields.Add('"schemaVersion":"1.0"')
        [void]$fields.Add('"scope":' + (ConvertTo-JsonString $scope))
        [void]$fields.Add('"time":' + (ConvertTo-JsonString (Fmt-DateSafe $e.TimeCreated)))
        [void]$fields.Add('"utc":' + (ConvertTo-JsonString (Fmt-UtcSafe $e.TimeCreated)))
        [void]$fields.Add('"log":' + (ConvertTo-JsonString ([string]$e.LogName)))
        [void]$fields.Add('"level":' + (ConvertTo-JsonString $lvl))
        [void]$fields.Add('"levelId":' + $eventLevelId)
        [void]$fields.Add('"provider":' + (ConvertTo-JsonString ([string]$e.ProviderName)))
        [void]$fields.Add('"id":' + [int]$e.Id)
        [void]$fields.Add('"recordId":' + $recordId)
        [void]$fields.Add('"task":' + (ConvertTo-JsonString $task))
        [void]$fields.Add('"opcode":' + (ConvertTo-JsonString $opcode))
        [void]$fields.Add('"keywords":' + (ConvertTo-JsonString $keywords))
        [void]$fields.Add('"processId":' + $(if ($null -eq $processId) { 'null' } else { [string]$processId }))
        [void]$fields.Add('"threadId":' + $(if ($null -eq $threadId) { 'null' } else { [string]$threadId }))
        [void]$fields.Add('"user":' + (ConvertTo-JsonString $uid))
        [void]$fields.Add('"props":' + (ConvertTo-JsonString $propsOut))
        [void]$fields.Add('"propsArray":' + $propsJson)
        [void]$fields.Add('"message":' + (ConvertTo-JsonString $msg))
        if ($IncludeXml) {
            $xml = ''
            try { $xml = [string]$e.ToXml() } catch { $xml = '' }
            [void]$fields.Add('"xml":' + (ConvertTo-JsonString $xml))
        }
        [void]$sb.Append('{' + ($fields -join ',') + "}`r`n")
    }

    $fileRel = ''
    if ($events.Count -gt 0) {
        $filePath = Join-Path $TargetDir ((Get-SafeFileName $LogName) + '.jsonl')
        Write-TextFile -Path $filePath -Text $sb.ToString()
        $fileRel = $filePath.Substring($runDir.Length + 1)
    }

    $firstT = ''
    $lastT = ''
    if ($events.Count -gt 0) { $firstT = Fmt-DateShort $events[0].TimeCreated; $lastT = Fmt-DateShort $events[-1].TimeCreated }
    $st = 'ok'
    if ($events.Count -eq 0) { $st = 'empty' }
    $null = $script:LogStats.Add([pscustomobject]@{
            stage = $Stage; log = $LogName; file = $fileRel; collected = $events.Count
            inWindow = $inWindow; inLead = $inLead; firstEvent = $firstT; lastEvent = $lastT
            queryStart = Fmt-DateSafe $leadStart; queryEnd = Fmt-DateSafe $winEnd; levelFilter = @($levelFilter)
            capped = $capped; note = $Note
        })
    $result = [pscustomobject]@{ ok = $true; log = $LogName; status = $st; count = $events.Count; detail = $(if ($capped) { "已达上限 $MaxEventsPerLog 条" } else { '' }); file = $fileRel }
    $script:EventSetResults[$cacheKey] = $result
    return $result
}

# 事件通道发现：优先使用事件日志 API，失败时回退注册表
function Get-EventChannelMap {
    $channels = @{}
    $publishers = @{}
    try {
        $names = @(Invoke-Native 'wevtutil' @('el') | Where-Object { $_ -and $_ -notmatch '^命令执行失败:' -and $_ -notmatch '^The following command' })
        foreach ($name in $names) {
            $channel = ([string]$name).Trim()
            if (-not $channel) { continue }
            $provider = ($channel -replace '/[^/]*$', '')
            $channels[$channel] = [pscustomobject]@{ channel = $channel; provider = $provider; enabled = $null }
        }
        if ($channels.Count -gt 0) {
            Add-Source '事件通道清单（wevtutil）' 'ok' '使用系统工具发现通道；用于内核日志与服务专属日志匹配' $channels.Count
            return @{ channels = $channels; publishers = $publishers }
        }
    } catch {
        Add-Source '事件通道清单（wevtutil）' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message
    }
    try {
        $logs = @(Get-WinEvent -ListLog * -ErrorAction Stop)
        foreach ($log in $logs) {
            $provider = ''
            try { $provider = (@($log.ProviderNames) | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join ';' } catch { $provider = '' }
            if (-not $provider) { $provider = ([string]$log.LogName -replace '/[^/]*$', '') }
            $enabled = $null
            try { if ($null -ne $log.IsEnabled) { $enabled = [bool]$log.IsEnabled } } catch { }
            $channels[[string]$log.LogName] = [pscustomobject]@{ channel = [string]$log.LogName; provider = $provider; enabled = $enabled }
        }
        if ($channels.Count -gt 0) {
            Add-Source '事件通道清单（事件日志 API）' 'ok' '用于发现内核日志与服务专属日志' $channels.Count
            return @{ channels = $channels; publishers = $publishers }
        }
    } catch {
        Add-Source '事件通道清单（事件日志 API）' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message
    }
    try {
        $pb = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Publishers'
        foreach ($x in @(Get-ChildItem $pb -ErrorAction Stop)) {
            $v = Get-ItemProperty $x.PSPath -ErrorAction SilentlyContinue
            if ($v -and $null -ne $v.'(default)') { $publishers[$x.PSChildName] = [string]$v.'(default)' }
        }
        Add-Source '事件发布者清单（注册表回退）' 'ok' '' $publishers.Count
    } catch { Add-Source '事件发布者清单（注册表回退）' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }
    try {
        $ch = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels'
        foreach ($x in @(Get-ChildItem $ch -ErrorAction Stop)) {
            $v = Get-ItemProperty $x.PSPath -ErrorAction SilentlyContinue
            $pubGuid = ''
            $enabled = $null
            if ($v) { $pubGuid = [string]$v.OwningPublisher; if ($null -ne $v.Enabled) { $enabled = [int]$v.Enabled } }
            $provider = ''
            if ($pubGuid -and $publishers.ContainsKey($pubGuid)) { $provider = $publishers[$pubGuid] }
            if (-not $provider) { $provider = ($x.PSChildName -replace '/[^/]*$', '') }
            $channels[$x.PSChildName] = [pscustomobject]@{ channel = $x.PSChildName; provider = $provider; enabled = $enabled }
        }
        Add-Source '事件通道清单（注册表回退）' 'ok' '用于发现内核日志与服务专属日志' $channels.Count
    } catch { Add-Source '事件通道清单（注册表回退）' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }
    return @{ channels = $channels; publishers = $publishers }
}

function Get-KernelChannelReason {
    param($ChannelInfo)
    if ($null -eq $ChannelInfo) { return '' }
    $channel = [string]$ChannelInfo.channel
    $provider = [string]$ChannelInfo.provider
    $text = ($channel + ' ' + $provider)
    $rules = @(
        @{ pattern = '(?i)(^|[/\\])Microsoft-Windows-Kernel-' ; reason = 'Microsoft-Windows-Kernel-*' },
        @{ pattern = '(?i)(^|[/\\])Kernel[-/]' ; reason = 'Kernel-* 通道' },
        @{ pattern = '(?i)WHEA-Logger' ; reason = '硬件错误/WHEA' },
        @{ pattern = '(?i)(^|[/\\])Microsoft-Windows-(Disk|Ntfs|volmgr|volsnap|partmgr|storahci|stornvme|Storage-ClassPnP)' ; reason = '磁盘/存储内核相关通道' },
        @{ pattern = '(?i)(^|[/\\])Microsoft-Windows-(Display|DxgKrnl|HAL|USB)' ; reason = '显示/硬件内核相关通道' }
    )
    foreach ($rule in $rules) { if ($text -match $rule.pattern) { return $rule.reason } }
    return ''
}

# =====================================================================
# 阶段 01：系统事件
# =====================================================================
Write-Host '[1/4] 采集系统事件（01_system_events）...' -ForegroundColor Gray
$sysIdList = @(12,13,20,27,41,42,107,109,506,507,1001,1074,2004,6005,6006,6008,6009,6013,219,55,98,137,140,7,11,51,52,153,157,129,7040,7045,7036,7009,7031,7034,104)
if ($includeBlueScreen -or $includeBlackScreen) { $sysIdList += @(19,4101,1000,1001,1002,1026) }
if ($includeServiceDown) { $sysIdList += @(7000,7001,7009,7011,7023,7024,7031,7032,7034,7035,7036,7040,7045) }
$sysIdList = @($sysIdList | Sort-Object -Unique)
$sysTargets = @(
    @{ log = 'System'; ids = $sysIdList; note = '系统日志：启动/关机/电源/硬件/服务/磁盘等关键事件（含 Information 级 ID）' },
    @{ log = 'Application'; ids = @(1000,1001,1002,1026,11707,11708,8193,13,16384,16394,1003,1034,8230,490,1008); note = '应用日志：崩溃/挂起/.NET 异常/VSS/许可/安装等' },
    @{ log = 'Setup'; ids = @(); note = '安装程序日志' },
    @{ log = 'HardwareEvents'; ids = @(); note = '硬件事件' }
)
if ($includeBlueScreen) {
    $sysTargets += @(
        @{ log = 'Microsoft-Windows-WER-Diag/Operational'; ids = @(1001); note = '蓝屏/应用崩溃相关 WER 诊断通道（若系统存在）' },
        @{ log = 'Microsoft-Windows-DeviceSetupManager/Admin'; ids = @(); note = '设备/驱动安装与配置（蓝屏辅助证据）' }
    )
}
if ($includeBlackScreen) {
    $sysTargets += @(
        @{ log = 'Microsoft-Windows-Diagnostics-Performance/Operational'; ids = @(); note = '启动/登录/性能诊断（黑屏辅助证据）' },
        @{ log = 'Microsoft-Windows-Winlogon/Operational'; ids = @(); note = 'Winlogon/登录会话（黑屏辅助证据）' },
        @{ log = 'Microsoft-Windows-User Profiles Service/Operational'; ids = @(); note = '用户配置文件加载（黑屏辅助证据）' },
        @{ log = 'Microsoft-Windows-Dwm-Core/Operational'; ids = @(); note = '桌面窗口管理器（黑屏辅助证据）' },
        @{ log = 'Microsoft-Windows-DxgKrnl/Operational'; ids = @(); note = '图形内核（黑屏辅助证据）' },
        @{ log = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; ids = @(); note = '本地/RDP 会话（黑屏辅助证据）' },
        @{ log = 'Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational'; ids = @(); note = 'RDP 图形会话（黑屏辅助证据）' }
    )
}
if ($includeServiceDown) {
    $sysTargets += @(
        @{ log = 'Microsoft-Windows-ServiceControlManager/Operational'; ids = @(7000,7001,7009,7011,7023,7024,7031,7032,7034,7035,7036); note = '服务启动/停止/失败辅助通道（若系统存在）' },
        @{ log = 'Microsoft-Windows-TaskScheduler/Operational'; ids = @(); note = '服务依赖的任务调度活动（ServiceDown 辅助证据）' }
    )
}
$targetSeen = @{}
$sysTargets = @($sysTargets | Where-Object {
        $key = [string]$_.log
        if ($targetSeen.ContainsKey($key)) { $false } else { $targetSeen[$key] = $true; $true }
    })
foreach ($t in $sysTargets) {
    $r = Save-EventSet -Stage '01_system_events' -LogName $t.log -TargetDir $dirSystemEvents -ExtraIds $t.ids -Note $t.note
    Add-Source ('系统事件:' + $t.log) $r.status $r.detail $r.count
    if ($r.count -gt 0) { Write-Host ('      {0,-42} {1,7} 条' -f $t.log, $r.count) }
}
if ($IncludeSecurity -or $script:IsAdmin) {
    $r = Save-EventSet -Stage '01_system_events' -LogName 'Security' -TargetDir $dirSystemEvents -ExtraIds @(4624,4625,4634,4647,4672,4688,4740,4771,4776,5152,5156,5157,1102) -Note '安全日志：登录/认证/账户/WFP 拦截（需管理员）'
    Add-Source '系统事件:Security' $r.status $r.detail $r.count
    if ($r.count -gt 0) { Write-Host ('      Security {0} 条' -f $r.count) }
} else {
    Add-Source '系统事件:Security' 'denied' '非管理员会话；加 -IncludeSecurity -Elevate 可采集'
}
# =====================================================================
# 阶段 02：内核信息
# =====================================================================
Write-Host '[2/4] 采集内核信息（02_kernel）...' -ForegroundColor Gray
$chanMap = Get-EventChannelMap
$kernelChannels = @()
$kernelChannelReasons = @{}
foreach ($k in $chanMap.channels.Keys) {
    $reason = Get-KernelChannelReason -ChannelInfo $chanMap.channels[$k]
    if ($reason) { $kernelChannels += $chanMap.channels[$k]; $kernelChannelReasons[$k] = $reason }
}
$kernelChannels = @($kernelChannels | Sort-Object channel)
$kWithData = 0
$kNoData = New-Object System.Collections.ArrayList
$kFailed = New-Object System.Collections.ArrayList
foreach ($kc in $kernelChannels) {
    $reason = $kernelChannelReasons[$kc.channel]
    $r = Save-EventSet -Stage '02_kernel' -LogName $kc.channel -TargetDir $dirKernelEvents -Note ('内核通道；选择原因：' + $reason + '；提供程序 ' + $kc.provider)
    if ($r.ok -and $r.count -gt 0) { $kWithData++ }
    elseif ($r.ok) { [void]$kNoData.Add($kc.channel) }
    else { [void]$kFailed.Add([pscustomobject]@{ channel = $kc.channel; status = $r.status; detail = $r.detail }) }
}
Add-Source '内核:事件通道（规则发现）' 'ok' ('共 {0} 个通道；有数据 {1}，无数据 {2}，不可读 {3}' -f $kernelChannels.Count, $kWithData, $kNoData.Count, $kFailed.Count) $kWithData
if ($kNoData.Count -gt 0) { Add-Source '内核:无数据的通道' 'empty' (($kNoData | Select-Object -First 40) -join ' ; ') 0 }
if ($kFailed.Count -gt 0) { Add-Source '内核:不可读的通道' 'error' (($kFailed | Select-Object -First 20 | ForEach-Object { $_.channel + ' [' + $_.status + ']' }) -join ' ; ') $kFailed.Count }
Write-JsonFile -Path (Join-Path $dirKernel 'kernel_channel_inventory.json') -Object ([ordered]@{
        note = '按通道名/提供程序名规则发现的内核与硬件相关事件通道；选择原因用于审计覆盖范围'
        channels = @($kernelChannels | ForEach-Object { [pscustomobject]@{ channel = $_.channel; provider = $_.provider; enabled = $_.enabled; selectionReason = $kernelChannelReasons[$_.channel] } })
        noData = @($kNoData)
        unreadable = @($kFailed)
    })
Write-Host ('      Kernel 通道 {0} 个，其中 {1} 个有数据' -f $kernelChannels.Count, $kWithData)

$kernelDrivers = @()
try {
    $regRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    $liveDrv = @{}
    try { foreach ($d in @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop)) { $liveDrv[$d.Name] = $d } } catch { }
    foreach ($k in @(Get-ChildItem $regRoot -ErrorAction SilentlyContinue)) {
        $p = $null
        try { $p = Get-ItemProperty $k.PSPath -ErrorAction Stop } catch { continue }
        if ($null -eq $p.Type) { continue }
        $low = ([int]$p.Type) -band 0xFF
        if ($low -ne 1 -and $low -ne 2 -and $low -ne 8) { continue }
        $st = ''
        $started = $null
        if ($liveDrv.ContainsKey($k.PSChildName)) { $st = [string]$liveDrv[$k.PSChildName].State; $started = $liveDrv[$k.PSChildName].Started }
        $kernelDrivers += [pscustomobject]@{
            name = $k.PSChildName; displayName = [string]$p.DisplayName; type = $low
            typeText = $(switch ($low) { 1 { '内核驱动' } 2 { '文件系统驱动' } 8 { '文件系统识别驱动' } default { [string]$low } })
            start = $p.Start; state = $st; started = $started; imagePath = [string]$p.ImagePath
            group = [string]$p.Group; errorControl = $p.ErrorControl
        }
    }
    Add-Source '内核:驱动清单（注册表 Type=1/2/8）' 'ok' 'start: 0=引导 1=系统 2=自动 3=手动 4=禁用' $kernelDrivers.Count
} catch { Add-Source '内核:驱动清单（注册表 Type=1/2/8）' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }
Write-JsonFile -Path (Join-Path $dirKernel 'kernel_drivers.json') -Object ([ordered]@{
        note = '来自 HKLM\SYSTEM\CurrentControlSet\Services；type 低位 1=内核驱动 2=文件系统驱动 8=文件系统识别驱动'
        count = $kernelDrivers.Count
        drivers = @($kernelDrivers | Sort-Object name)
    })
Write-Host ('      内核驱动 {0} 个' -f $kernelDrivers.Count)

try {
    $drvOut = Invoke-Native 'driverquery' @('/fo','csv','/v')
    if ($drvOut.Count -gt 2) {
        Write-TextFile -Path (Join-Path $dirKernel 'driverquery.csv') -Text (($drvOut | Where-Object { $_ -match '\S' }) -join "`r`n")
        Add-Source '内核:driverquery' 'ok' '' $drvOut.Count
    } else { Add-Source '内核:driverquery' 'empty' '无有效输出（通常需要管理员）' }
} catch { Add-Source '内核:driverquery' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }

$dumpList = @()
$dumpCopyCount = 0
$dumpCopySkipped = 0
$dumpCopyRoot = Join-Path $dirKernel 'crash_dumps'
$dumpMaxCopyBytes = 256MB
$dumpRoots = @("$env:SystemRoot\MEMORY.DMP", "$env:SystemRoot\Minidump", "$env:SystemRoot\LiveKernelReports")
try {
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    foreach ($profileDir in @(Get-ChildItem $usersRoot -Directory -ErrorAction SilentlyContinue)) {
        $dumpRoots += (Join-Path $profileDir.FullName 'AppData\Local\CrashDumps')
    }
} catch { }
foreach ($dp in @($dumpRoots | Select-Object -Unique)) {
    if (-not (Test-Path $dp)) { continue }
    $it = Get-Item $dp -ErrorAction SilentlyContinue
    $dumpFiles = @()
    if ($it -is [System.IO.DirectoryInfo]) { $dumpFiles = @(Get-ChildItem $dp -Recurse -File -ErrorAction SilentlyContinue) }
    elseif ($it) { $dumpFiles = @($it) }
    foreach ($df in $dumpFiles) {
        $modified = $df.LastWriteTime
        $scope = 'outside'
        if ($modified -ge $leadStart -and $modified -le $winEnd) { $scope = $(if ($modified -ge $winStart) { 'window' } else { 'lead' }) }
        $kind = 'dump'
        if ($df.FullName -match '(?i)Minidump') { $kind = 'minidump' }
        elseif ($df.FullName -match '(?i)LiveKernelReports') { $kind = 'live-kernel-report' }
        elseif ($df.Name -ieq 'MEMORY.DMP') { $kind = 'memory-dump' }
        $copyStatus = 'not-requested'
        $copyPath = ''
        $sha256 = ''
        if ($IncludeCrashDumps -and $scope -ne 'outside' -and $df.Length -le $dumpMaxCopyBytes -and $kind -ne 'memory-dump') {
            try {
                if (-not (Test-Path $dumpCopyRoot)) { New-Item -ItemType Directory -Path $dumpCopyRoot -Force | Out-Null }
                $destName = '{0}_{1}' -f $kind, (Get-SafeFileName $df.Name)
                $dest = Join-Path $dumpCopyRoot $destName
                Copy-Item -LiteralPath $df.FullName -Destination $dest -Force -ErrorAction Stop
                $copyPath = $dest.Substring($runDir.Length + 1)
                $sha256 = Get-FileSha256Safe -Path $dest
                $copyStatus = 'copied'
                $dumpCopyCount++
            } catch { $copyStatus = 'copy-failed: ' + (Compact-Text $_.Exception.Message 160) }
        } elseif ($IncludeCrashDumps -and $scope -ne 'outside') {
            $copyStatus = $(if ($df.Length -gt $dumpMaxCopyBytes) { 'skipped-large' } else { 'skipped-memory-dump' })
            $dumpCopySkipped++
        }
        $dumpList += [pscustomobject]@{
            path = $df.FullName; kind = $kind; sizeMB = [math]::Round($df.Length / 1MB, 2)
            modified = Fmt-DateSafe $modified; scope = $scope; copyStatus = $copyStatus; copyFile = $copyPath; sha256 = $sha256
        }
    }
}
Write-JsonFile -Path (Join-Path $dirKernel 'crash_dumps.json') -Object ([ordered]@{ note = '转储清单；默认不复制大文件，-IncludeCrashDumps 可复制窗口内不超过 256MB 的小型转储'; count = $dumpList.Count; copied = $dumpCopyCount; skipped = $dumpCopySkipped; dumps = $dumpList })
Add-Source '内核:崩溃转储与实时内核报告清单' $(if ($dumpList.Count -gt 0) { 'ok' } else { 'empty' }) '包含范围、修改时间和复制状态' $dumpList.Count
if ($IncludeCrashDumps) { Add-Source '内核:窗口内小型转储复制' $(if ($dumpCopyCount -gt 0) { 'ok' } else { 'empty' }) ('复制 {0} 个，跳过 {1} 个' -f $dumpCopyCount, $dumpCopySkipped) $dumpCopyCount }

$werList = @()
if ($includeBlueScreen -or $includeBlackScreen) {
    $werErrors = New-Object System.Collections.ArrayList
    $werRoots = @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
        (Join-Path $env:LOCALAPPDATA 'CrashDumps')
    ) | Where-Object { $_ -and (Test-Path $_) }
    try {
        $usersRoot = Join-Path $env:SystemDrive 'Users'
        foreach ($profileDir in @(Get-ChildItem $usersRoot -Directory -ErrorAction SilentlyContinue)) {
            $werRoots += (Join-Path $profileDir.FullName 'AppData\Local\CrashDumps')
        }
    } catch { }
    $werRoots = @($werRoots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
    foreach ($wr in $werRoots) {
        $werFiles = @()
        try { $werFiles = @(Get-ChildItem $wr -Recurse -File -ErrorAction Stop | Where-Object { $_.LastWriteTime -ge $leadStart -and $_.LastWriteTime -le $winEnd -and ($_.Extension -ieq '.wer' -or $_.Name -ieq 'Report.wer') }) }
        catch { [void]$werErrors.Add(('{0}: {1}' -f $wr, $_.Exception.Message)); continue }
        foreach ($wf in $werFiles) {
            $content = ''
            $contentTruncated = $false
            try {
                if ($wf.Length -le 256KB) { $content = [System.IO.File]::ReadAllText($wf.FullName) }
                else { $content = [System.IO.File]::ReadAllText($wf.FullName).Substring(0, 256KB); $contentTruncated = $true }
            } catch { }
            $werList += [pscustomobject]@{
                path = $wf.FullName; sizeKB = [math]::Round($wf.Length / 1KB, 1); modified = Fmt-DateSafe $wf.LastWriteTime
                scope = $(if ($wf.LastWriteTime -ge $winStart) { 'window' } else { 'lead' }); content = $content; contentTruncated = $contentTruncated
            }
        }
    }
    Write-JsonFile -Path (Join-Path $dirKernel 'wer_reports.json') -Object ([ordered]@{ note = '窗口内 WER 文本报告；用于蓝屏、应用崩溃和黑屏辅助分析'; count = $werList.Count; reports = $werList })
    $werStatus = 'empty'
    if ($werList.Count -gt 0) { $werStatus = 'ok' } elseif ($werErrors.Count -gt 0) { $werStatus = Get-ErrStatus (($werErrors | Select-Object -First 3) -join ' ; ') }
    Add-Source '异常:Windows Error Reporting 文本报告' $werStatus $(if ($werErrors.Count -gt 0) { (($werErrors | Select-Object -First 3) -join ' ; ') } else { '仅读取窗口/前导期内的 .wer 报告' }) $werList.Count
}

$kernelState = [ordered]@{ collectedAt = Fmt-DateSafe $script:Now }
try { $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop; $kernelState['os'] = ('{0} {1} Build {2}.{3}' -f $cv.ProductName, $cv.DisplayVersion, $cv.CurrentBuildNumber, $cv.UBR); $kernelState['buildLab'] = $cv.BuildLabEx } catch { }
try { $kernelState['kernelVersion'] = [string][System.Environment]::OSVersion.Version } catch { }
try {
    $up = (Get-Counter '\System\System Up Time' -MaxSamples 1 -ErrorAction Stop).CounterSamples[0].CookedValue
    $kernelState['uptimeSeconds'] = [math]::Round($up, 0)
    $kernelState['estimatedBootTime'] = Fmt-DateShort $script:Now.AddSeconds(-1 * $up)
} catch { }
try {
    $mm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -ErrorAction Stop
    $kernelState['memoryManagement'] = [ordered]@{ pagingFiles = ($mm.PagingFiles -join '; '); existingPageFiles = ($mm.ExistingPageFiles -join '; ') }
} catch { }
try { $kernelState['crashControl'] = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop | Select-Object CrashDumpEnabled, DumpFile, MinidumpDir, AutoReboot, Overwrite, LogEvent, MinidumpsCount, AlwaysKeepMemoryDump } catch { }
try { $kernelState['fastStartup'] = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled } catch { }
try {
    $boot = Invoke-Native 'bcdedit' @('/enum')
    if ($boot.Count -gt 1) { Write-TextFile -Path (Join-Path $dirKernel 'bcdedit.txt') -Text ($boot -join "`r`n"); Add-Source '内核:启动配置(bcdedit)' 'ok' '' $boot.Count }
    else { Add-Source '内核:启动配置(bcdedit)' 'denied' '读取启动配置通常需要管理员' }
} catch { Add-Source '内核:启动配置(bcdedit)' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }
Write-JsonFile -Path (Join-Path $dirKernel 'kernel_state.json') -Object $kernelState

$pfwPath = ''
foreach ($pp in @((Join-Path $env:SystemRoot 'System32\LogFiles\Firewall\pfirewall.log'),'C:\Windows\System32\LogFiles\Firewall\pfirewall.log')) { if (Test-Path $pp) { $pfwPath = $pp; break } }
if ($pfwPath) {
    try {
        $pfwAll = @(Get-Content $pfwPath -ErrorAction Stop)
        Write-TextFile -Path (Join-Path $dirKernel 'pfirewall_full.txt') -Text (($pfwAll | Select-Object -Last 50000) -join "`r`n")
        $fields = @()
        $inWinLines = New-Object System.Collections.ArrayList
        foreach ($ln in $pfwAll) {
            if (-not $ln) { continue }
            if ($ln.StartsWith('#Fields:')) { $fields = @(($ln.Substring(8).Trim() -split '\s+')); [void]$inWinLines.Add($ln); continue }
            if ($ln.StartsWith('#')) { [void]$inWinLines.Add($ln); continue }
            $parts = @($ln -split '\s+')
            if ($fields.Count -eq 0 -or $parts.Count -lt 6) { continue }
            $rec = @{}
            for ($i = 0; $i -lt $fields.Count -and $i -lt $parts.Count; $i++) { $rec[$fields[$i]] = $parts[$i] }
            $t = $null
            try { $t = [datetime]::Parse(('{0} {1}' -f $rec['date'], $rec['time']), [Globalization.CultureInfo]::InvariantCulture) } catch { $t = $null }
            if ($null -ne $t -and $t -ge $leadStart -and $t -le $winEnd) { [void]$inWinLines.Add($ln) }
        }
        Write-TextFile -Path (Join-Path $dirKernel 'pfirewall_window.txt') -Text ($inWinLines -join "`r`n")
        Add-Source '内核:防火墙丢包日志(pfirewall.log)' 'ok' $pfwPath $inWinLines.Count
    } catch { Add-Source '内核:防火墙丢包日志(pfirewall.log)' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }
} else {
    Add-Source '内核:防火墙丢包日志(pfirewall.log)' 'missing' '未启用防火墙丢包日志（丢包不写事件日志，只写这个文件）'
}

# =====================================================================
# 阶段 03：运行服务清单
# =====================================================================
Write-Host '[3/4] 采集运行服务清单（03_services）...' -ForegroundColor Gray
$allServices = @()
try {
    $regRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
    $liveSvc = @{}
    foreach ($s in @(Get-Service -ErrorAction SilentlyContinue)) { $liveSvc[$s.Name] = $s }
    foreach ($k in @(Get-ChildItem $regRoot -ErrorAction SilentlyContinue)) {
        $p = $null
        try { $p = Get-ItemProperty $k.PSPath -ErrorAction Stop } catch { continue }
        if ($null -eq $p.Type) { continue }
        $low = ([int]$p.Type) -band 0xFF
        if ($low -ne 0x10 -and $low -ne 0x20) { continue }
        $name = $k.PSChildName
        $status = ''
        if ($liveSvc.ContainsKey($name)) { $status = [string]$liveSvc[$name].Status }
        $allServices += [pscustomobject]@{
            name = $name; displayName = [string]$p.DisplayName; status = $status
            start = $p.Start; delayedAutoStart = $p.DelayedAutoStart
            serviceType = $low
            serviceTypeText = $(switch ($low) { 0x10 { '自有进程' } 0x20 { '共享进程(svchost 等)' } default { [string]$low } })
            imagePath = [string]$p.ImagePath; account = [string]$p.ObjectName
            dependsOn = [string]$p.DependOnService
            pid = $null; process = ''; processPath = ''; processStartTime = ''; workingSetMB = $null
        }
    }
    Add-Source '服务清单（注册表 + SCM）' 'ok' 'start: 0=引导 1=系统 2=自动 3=手动 4=禁用' $allServices.Count
} catch { Add-Source '服务清单（注册表 + SCM）' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }

$svcPidMap = @{}
try {
    foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction Stop)) { if ($s.ProcessId -and $s.ProcessId -gt 0) { $svcPidMap[$s.Name] = [int]$s.ProcessId } }
    Add-Source '服务进程PID（WMI Win32_Service）' 'ok' '' $svcPidMap.Count
} catch { Add-Source '服务进程PID（WMI Win32_Service）' (Get-ErrStatus $_.Exception.Message) '需要 WMI 权限；已改为按映像路径匹配进程' }

$procList = @()
foreach ($pr in @(Get-Process -ErrorAction SilentlyContinue)) {
    $path = ''
    try { $path = [string]$pr.Path } catch { $path = '' }
    $st = ''
    try { $st = Fmt-DateShort $pr.StartTime } catch { $st = '' }
    $procList += [pscustomobject]@{ name = $pr.ProcessName; pid = [int]$pr.Id; path = $path; startTime = $st; wsMB = [math]::Round($pr.WorkingSet64 / 1MB, 1); cpuSeconds = $(try { [math]::Round($pr.CPU, 1) } catch { $null }) }
}
$procByPid = @{}
$procByPath = @{}
foreach ($p in $procList) { $procByPid[[string]$p.pid] = $p; if ($p.path) { $procByPath[$p.path.ToLowerInvariant()] = $p } }

foreach ($s in $allServices) {
    $found = $null
    if ($svcPidMap.ContainsKey($s.name)) {
        $sp = [string]$svcPidMap[$s.name]
        if ($procByPid.ContainsKey($sp)) { $found = $procByPid[$sp] }
    }
    if (-not $found -and $s.status -eq 'Running' -and $s.imagePath) {
        $exe = [string]$s.imagePath
        $exe = $exe -replace '^\\\?\?\\', ''
        $exe = $exe -replace '^\\SystemRoot', $env:SystemRoot
        $exe = $exe -replace '^"([^"]+)".*$', '$1'
        $exe = ($exe -split '\s+')[0]
        if ($exe -and $procByPath.ContainsKey($exe.ToLowerInvariant())) { $found = $procByPath[$exe.ToLowerInvariant()] }
    }
    if ($found) {
        $s.pid = $found.pid; $s.process = $found.name; $s.processPath = $found.path
        $s.processStartTime = $found.startTime; $s.workingSetMB = $found.wsMB
    }
}
$runningServices = @($allServices | Where-Object { $_.status -eq 'Running' })
Write-JsonFile -Path (Join-Path $dirServices 'all_services.json') -Object ([ordered]@{
        note = '全部服务（含未运行）。status 来自 SCM；start/delayedAutoStart/serviceType/imagePath/account 为注册表原始值'
        count = $allServices.Count
        services = @($allServices | Sort-Object name)
    })
Write-JsonFile -Path (Join-Path $dirServices 'running_services.json') -Object ([ordered]@{
        note = '运行中的服务；pid/process/processPath 为采集时刻匹配到的进程（WMI 不可用时按映像路径匹配）'
        count = $runningServices.Count
        services = @($runningServices | Sort-Object name)
    })
Write-JsonFile -Path (Join-Path $dirServices 'processes.json') -Object ([ordered]@{ note = '采集时刻全部进程'; count = $procList.Count; processes = @($procList | Sort-Object wsMB -Descending) })
Add-Source '运行服务清单' 'ok' ('运行中 {0} 个 / 全部 {1} 个' -f $runningServices.Count, $allServices.Count) $runningServices.Count
Write-Host ('      运行服务 {0} 个 / 全部 {1} 个' -f $runningServices.Count, $allServices.Count)

$failureActionStatus = 'not_collected'
$failureActionSummary = [ordered]@{ attempted = 0; succeeded = 0; failed = 0; status = $failureActionStatus }
$failureActions = @()
$failureActionErrors = @()
if ($includeServiceDown) {
    $failureActions = New-Object System.Collections.ArrayList
    $failureActionErrors = New-Object System.Collections.ArrayList
    $scExe = Join-Path $env:SystemRoot 'System32\sc.exe'
    $failureCandidates = @($allServices | Where-Object { $_.start -ne 4 } | Sort-Object name)
    foreach ($svc in $failureCandidates) {
        $fo = @()
        $exitCode = -1
        try {
            $fo = @(& $scExe 'qfailure' ([string]$svc.name) 2>&1)
            $exitCode = [int]$LASTEXITCODE
        } catch {
            $fo = @($_.Exception.Message)
        }
        $foText = ($fo | ForEach-Object { [string]$_ }) -join "`r`n"
        if ($exitCode -eq 0 -and $foText -notmatch '(?im)^\s*\[SC\].*FAILED') {
            [void]$failureActions.Add([pscustomobject]@{ service = $svc.name; displayName = $svc.displayName; output = $foText })
        } else {
            $status = 'error'
            if ($foText -match '(?i)FAILED\s+5\b|access is denied|access denied|拒绝访问') { $status = 'denied' }
            elseif ($foText -match '(?i)FAILED\s+1060\b|does not exist|不存在') { $status = 'missing' }
            [void]$failureActionErrors.Add([pscustomobject]@{ service = $svc.name; displayName = $svc.displayName; status = $status; exitCode = $exitCode; output = $foText })
        }
    }
    $failureActionStatus = 'ok'
    if ($failureCandidates.Count -eq 0) { $failureActionStatus = 'empty' }
    elseif ($failureActionErrors.Count -gt 0 -and $failureActions.Count -gt 0) { $failureActionStatus = 'partial' }
    elseif ($failureActionErrors.Count -gt 0) {
        $errorStatuses = @($failureActionErrors | ForEach-Object { $_.status } | Sort-Object -Unique)
        if ($errorStatuses.Count -eq 1 -and $errorStatuses[0] -eq 'denied') { $failureActionStatus = 'denied' }
        else { $failureActionStatus = 'error' }
    }
    $failureActionSummary = [ordered]@{ attempted = $failureCandidates.Count; succeeded = $failureActions.Count; failed = $failureActionErrors.Count; status = $failureActionStatus }
    Write-JsonFile -Path (Join-Path $dirServices 'service_failure_actions.json') -Object ([ordered]@{
            note = 'ServiceDown 画像：SCM 服务失败恢复策略采集时刻快照；不是指定时间段内的历史策略。每项保留 sc.exe 原始输出。'
            status = $failureActionStatus; attempted = $failureCandidates.Count; succeeded = $failureActions.Count; failed = $failureActionErrors.Count
            services = @($failureActions); errors = @($failureActionErrors)
        })
    $failureDetail = '采集时刻快照；成功 {0}，失败 {1}' -f $failureActions.Count, $failureActionErrors.Count
    Add-Source '服务Down:SCM 失败恢复策略(sc qfailure)' $failureActionStatus $failureDetail $failureActions.Count
}

if ($includeBlackScreen) {
    $displayAdapters = @()
    try {
        $displayAdapters = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                name = [string]$_.Name; status = [string]$_.Status; driverVersion = [string]$_.DriverVersion
                driverDate = [string]$_.DriverDate; adapterRamMB = $(if ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1MB, 1) } else { $null })
                pnpDeviceId = [string]$_.PNPDeviceID; videoMode = [string]$_.VideoModeDescription
                refreshRate = $_.CurrentRefreshRate; horizontal = $_.CurrentHorizontalResolution; vertical = $_.CurrentVerticalResolution
            }
        })
        Add-Source '黑屏:显示适配器(WMI)' 'ok' '' $displayAdapters.Count
    } catch { Add-Source '黑屏:显示适配器(WMI)' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }
    Write-JsonFile -Path (Join-Path $dirServices 'display_adapters.json') -Object ([ordered]@{ collectedAt = Fmt-DateSafe $script:Now; count = $displayAdapters.Count; adapters = $displayAdapters })
    $interactiveNames = @('dwm','winlogon','explorer','LogonUI','csrss','rdpclip','mstsc','RuntimeBroker')
    $interactiveProcesses = @($procList | Where-Object { $interactiveNames -contains $_.name })
    Write-JsonFile -Path (Join-Path $dirServices 'interactive_processes.json') -Object ([ordered]@{ note = '黑屏相关交互进程采集时刻快照'; count = $interactiveProcesses.Count; processes = $interactiveProcesses })
    foreach ($qc in @(
            @{ name = 'quser.txt'; cmd = 'quser'; args = @() },
            @{ name = 'query_session.txt'; cmd = 'query'; args = @('session') },
            @{ name = 'query_user.txt'; cmd = 'query'; args = @('user') }
        )) {
        $qo = Invoke-Native $qc.cmd $qc.args
        if ($qo.Count -gt 0) { Write-TextFile -Path (Join-Path $dirServices $qc.name) -Text ($qo -join "`r`n") }
        Add-Source ('黑屏:' + $qc.name) $(if ($qo.Count -gt 0) { 'ok' } else { 'empty' }) '交互会话快照' $qo.Count
    }
}

# =====================================================================
# 阶段 04：运行服务的日志（按服务名匹配事件通道）
# =====================================================================
Write-Host '[4/4] 采集运行服务的日志（04_service_logs）...' -ForegroundColor Gray
$stopWords = @('windows','microsoft','service','services','host','system','client','server','manager','update','updater','runtime','common','helper','engine','monitor','framework','core','base','driver','device','devices','tools','tool','agent','local','network','security','defender','print','audio','time','task','scheduler','event','events','store','cache','power','boot','disk','file','files','data','state','app','apps','user','users','admin','proc','main','test','support','telemetry','experience','platform','resource','virtual','smart','shared','remote','direct','default','generic','module','library','extension','installer','setup','config','management','provider','application','svchost','exe','dll','sys','win','x64','x86')

function Get-ServiceTokens {
    param($Service)
    $tokens = @{}
    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add([string]$Service.name)
    [void]$candidates.Add([string]$Service.displayName)
    $ip = [string]$Service.imagePath
    if ($ip) {
        $exe = $ip -replace '^\\\?\?\\', ''
        $exe = $exe -replace '^"([^"]+)".*$', '$1'
        $exe = ($exe -split '\s+')[0]
        try { $exe = [System.IO.Path]::GetFileNameWithoutExtension($exe) } catch { }
        if ($exe) { [void]$candidates.Add($exe) }
    }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        foreach ($part in ($c -split '[^0-9A-Za-z]+')) {
            $t = $part.ToLowerInvariant()
            if ($t.Length -lt 4) { continue }
            if ($stopWords -contains $t) { continue }
            if ($t -match '^\d+$') { continue }
            $tokens[$t] = $true
        }
    }
    return @($tokens.Keys)
}

$chanNames = @($chanMap.channels.Keys)
$chanLower = @{}
foreach ($c in $chanNames) { $chanLower[$c] = $c.ToLowerInvariant() }
$chanProvLower = @{}
foreach ($c in $chanNames) { $p = ''; if ($chanMap.channels[$c]) { $p = [string]$chanMap.channels[$c].provider }; $chanProvLower[$c] = $p.ToLowerInvariant() }
$channelCandidatesByToken = @{}
foreach ($c in $chanNames) {
    $channelParts = @(([string]$c -split '[^0-9A-Za-z]+') + ([string]$chanProvLower[$c] -split '[^0-9A-Za-z]+'))
    foreach ($part in $channelParts) {
        $ct = ([string]$part).ToLowerInvariant()
        if ($ct.Length -lt 4 -or $stopWords -contains $ct -or $ct -match '^\d+$') { continue }
        if (-not $channelCandidatesByToken.ContainsKey($ct)) { $channelCandidatesByToken[$ct] = New-Object System.Collections.ArrayList }
        if (@($channelCandidatesByToken[$ct]) -notcontains $c) { [void]$channelCandidatesByToken[$ct].Add($c) }
    }
}

$svcMatch = New-Object System.Collections.ArrayList
$matchedChannels = @{}
foreach ($s in $runningServices) {
    $tokens = Get-ServiceTokens -Service $s
    $hits = @{}
    $hitRules = @{}
    foreach ($tk in $tokens) {
        $candidateChannels = @($channelCandidatesByToken[$tk] | ForEach-Object { [string]$_ } | Where-Object { $_ })
        foreach ($c in $candidateChannels) {
            $score = 0
            $rules = New-Object System.Collections.ArrayList
            if ($chanLower[$c] -eq $tk) { $score += 5; [void]$rules.Add('channel-exact') }
            elseif ($chanLower[$c].Contains($tk)) { $score += 2; [void]$rules.Add('channel-contains') }
            if ($chanProvLower[$c] -eq $tk) { $score += 6; [void]$rules.Add('provider-exact') }
            elseif ($chanProvLower[$c] -and $chanProvLower[$c].Contains($tk)) { $score += 3; [void]$rules.Add('provider-contains') }
            if ($score -gt 0) {
                if (-not $hits.ContainsKey($c) -or $score -gt $hits[$c]) { $hits[$c] = $score }
                if (-not $hitRules.ContainsKey($c)) { $hitRules[$c] = New-Object System.Collections.ArrayList }
                foreach ($rule in $rules) { if (@($hitRules[$c]) -notcontains $rule) { [void]$hitRules[$c].Add($rule) } }
            }
        }
    }
    $hitDetails = @($hits.Keys | Sort-Object @{Expression={ $hits[$_] };Descending=$true}, @{Expression={ $_ }} | ForEach-Object {
            $score = [int]$hits[$_]
            $confidence = 'low'
            if ($score -ge 6) { $confidence = 'high' } elseif ($score -ge 3) { $confidence = 'medium' }
            [pscustomobject]@{ channel = $_; score = $score; confidence = $confidence; rules = @($hitRules[$_]) }
        })
    foreach ($h in $hitDetails) { $matchedChannels[$h.channel] = $true }
    $null = $svcMatch.Add([pscustomobject]@{
            service = $s.name; displayName = $s.displayName; status = $s.status; pid = $s.pid
            imagePath = $s.imagePath; matchTokens = ($tokens -join ',')
            matchedChannelCount = $hitDetails.Count; matchedChannels = @($hitDetails | ForEach-Object { $_.channel }); matchedChannelDetails = $hitDetails
        })
}
$matchedChannels = @($matchedChannels.Keys | Sort-Object)
$svcLogWithData = New-Object System.Collections.ArrayList
$svcLogNoData = New-Object System.Collections.ArrayList
$svcLogFailed = New-Object System.Collections.ArrayList
foreach ($c in $matchedChannels) {
    $prov = ''
    if ($chanMap.channels[$c]) { $prov = [string]$chanMap.channels[$c].provider }
    $r = Save-EventSet -Stage '04_service_logs' -LogName $c -TargetDir $dirServiceLogs -Note ('运行服务相关通道；提供程序 ' + $prov)
    if ($r.ok -and $r.count -gt 0) { $null = $svcLogWithData.Add([pscustomobject]@{ channel = $c; provider = $prov; count = $r.count; file = $r.file }) }
    elseif ($r.ok) { [void]$svcLogNoData.Add($c) }
    else { [void]$svcLogFailed.Add([pscustomobject]@{ channel = $c; status = $r.status; detail = $r.detail }) }
}
$noMatchServices = @($svcMatch | Where-Object { $_.matchedChannelCount -eq 0 })
Write-JsonFile -Path (Join-Path $dirServiceLogs '_service_log_mapping.json') -Object ([ordered]@{
        note = '运行服务 <-> 事件通道 的候选匹配结果。按服务名/显示名/映像文件名生成标识串，结合通道名与提供程序名评分；没有匹配不代表服务没有日志。'
        matchRule = 'channel/provider exact=高分，contains=中低分；confidence 仅表示名称关联强度，不是日志归属的确定证明'
        runningServices = $runningServices.Count
        servicesWithLogs = @($svcMatch | Where-Object { $_.matchedChannelCount -gt 0 }).Count
        servicesWithoutLogs = $noMatchServices.Count
        matchedChannelTotal = $matchedChannels.Count
        channelsWithData = $svcLogWithData.Count
        mapping = @($svcMatch | Sort-Object matchedChannelCount -Descending)
        channels = @($svcLogWithData)
        channelsWithoutData = @($svcLogNoData)
        channelsUnreadable = @($svcLogFailed)
        servicesWithoutMatchedChannel = @($noMatchServices | Select-Object service, displayName, imagePath)
    })
$svcLogStatus = 'ok'
if ($matchedChannels.Count -eq 0) { $svcLogStatus = 'empty' }
elseif ($svcLogFailed.Count -gt 0 -and $svcLogWithData.Count -gt 0) { $svcLogStatus = 'partial' }
elseif ($svcLogFailed.Count -gt 0) {
    $svcFailStatuses = @($svcLogFailed | ForEach-Object { $_.status } | Sort-Object -Unique)
    if ($svcFailStatuses.Count -eq 1 -and $svcFailStatuses[0] -eq 'denied') { $svcLogStatus = 'denied' } else { $svcLogStatus = 'error' }
}
elseif ($svcLogWithData.Count -eq 0) { $svcLogStatus = 'empty' }
Add-Source '服务日志:按服务匹配到的事件通道' $svcLogStatus ('匹配 {0} 个通道；有数据 {1}，无数据 {2}，不可读 {3}' -f $matchedChannels.Count, $svcLogWithData.Count, $svcLogNoData.Count, $svcLogFailed.Count) $svcLogWithData.Count
Add-Source '服务日志:未匹配到通道的运行服务' $(if ($noMatchServices.Count -gt 0) { 'ok' } else { 'empty' }) ('{0} 个运行服务没有找到名字对应的事件通道' -f $noMatchServices.Count) $noMatchServices.Count
Write-Host ('      匹配通道 {0} 个（有数据 {1}），未匹配服务 {2} 个' -f $matchedChannels.Count, $svcLogWithData.Count, $noMatchServices.Count)

foreach ($el in @($ExtraLogs | Where-Object { $_ })) {
    $r = Save-EventSet -Stage '99_user_extra' -LogName $el.Trim() -TargetDir $dirSystemEvents -Note '用户通过 -ExtraLogs 指定'
    Add-Source ('用户指定日志:' + $el.Trim()) $r.status $r.detail $r.count
}

# =====================================================================
# 主机状态 / 原始产物 / 基线计数
# =====================================================================
$hostState = [ordered]@{
    schemaVersion = '1.1'; collectionModel = 'window-events + current-running-service-snapshot + incident-profile-artifacts'; incidentProfile = $IncidentProfile; includeCrashDumps = $IncludeCrashDumps
    hostname = $hostLabel; account = $script:Identity.Name; isAdmin = $script:IsAdmin
    collectedAt = Fmt-DateSafe $script:Now; collectedAtUtc = Fmt-UtcSafe $script:Now
    timeZone = (Get-TimeZone).Id; utcOffset = $script:UtcOffsetText
    window = [ordered]@{ start = Fmt-DateSafe $winStart; end = Fmt-DateSafe $winEnd; minutes = $winMinutes; startUtc = Fmt-UtcSafe $winStart; endUtc = Fmt-UtcSafe $winEnd; source = $windowSource }
    lead = [ordered]@{ start = Fmt-DateSafe $leadStart; end = Fmt-DateSafe $winStart; minutes = $leadMinutes }
    baseline = [ordered]@{ start = $(if ($BaselineHours -gt 0) { Fmt-DateSafe $baseStart } else { '' }); end = $(if ($BaselineHours -gt 0) { Fmt-DateSafe $leadStart } else { '' }); hours = $BaselineHours }
    levels = $(if ($ErrorsOnly) { '1-3 + diagnostic ids' } else { '0-5 (all standard levels)' })
    maxMessageLength = $MaxMessageLength; maxEventsPerLog = $MaxEventsPerLog
}
try { $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop; $hostState['os'] = [ordered]@{ product = $cv.ProductName; version = $cv.DisplayVersion; build = ('{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR); arch = $env:PROCESSOR_ARCHITECTURE } } catch { }
try { $bios = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop; $hostState['hardware'] = [ordered]@{ manufacturer = [string]$bios.SystemManufacturer; product = [string]$bios.SystemProductName; biosVersion = [string]$bios.BIOSVersion; biosDate = [string]$bios.BIOSReleaseDate } } catch { }
try { $hostState['cpu'] = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).ProcessorNameString } catch { }
$hostState['logicalProcessors'] = [Environment]::ProcessorCount
try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $hostState['totalMemoryMB'] = [math]::Round($cs.TotalPhysicalMemory / 1MB, 0); Add-Source 'WMI:Win32_ComputerSystem' 'ok' '' 1 } catch { Add-Source 'WMI:Win32_ComputerSystem' (Get-ErrStatus $_.Exception.Message) $_.Exception.Message }
try { $hostState['volumes'] = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object { [pscustomobject]@{ drive = $_.Name; format = $_.DriveFormat; totalGB = [math]::Round($_.TotalSize / 1GB, 1); freeGB = [math]::Round($_.AvailableFreeSpace / 1GB, 1) } }) } catch { }
$hostState['timeSource'] = [ordered]@{
    configured = $(try { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction Stop) | ForEach-Object { 'Type=' + $_.Type + '; NtpServer=' + $_.NtpServer } } catch { '' })
    current    = ((Invoke-Native 'w32tm' @('/query','/source')) | Where-Object { $_ -notmatch [char]0xFFFD }) -join ' '
}
$hostState['pendingReboot'] = [ordered]@{
    cbsRebootPending = $(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    wuRebootRequired = $(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
}
Write-JsonFile -Path (Join-Path $dirState 'host_state.json') -Object $hostState

$installed = @()
foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
    if (-not (Test-Path $root)) { continue }
    foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $v = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if (-not $v -or -not $v.DisplayName) { continue }
        $installed += [pscustomobject]@{ name = $v.DisplayName; version = $v.DisplayVersion; publisher = $v.Publisher; installDate = [string]$v.InstallDate; installLocation = [string]$v.InstallLocation }
    }
}
$hotfix = @()
try { $hotfix = @(Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object HotFixID, Description, @{n='InstalledOn';e={Fmt-DateShort $_.InstalledOn}}) } catch { }
Add-Source 'Get-HotFix' $(if ($hotfix.Count -gt 0) { 'ok' } else { 'denied' }) '读取已安装补丁需要管理员' $hotfix.Count
Write-JsonFile -Path (Join-Path $dirState 'installed_software_updates.json') -Object ([ordered]@{ hotfixes = $hotfix; installedPrograms = $installed })
Add-Source '注册表:已安装软件' 'ok' '' $installed.Count

$startup = @()
foreach ($sk in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')) {
    if (-not (Test-Path $sk)) { continue }
    $v = Get-ItemProperty $sk -ErrorAction SilentlyContinue
    if (-not $v) { continue }
    foreach ($prop in $v.PSObject.Properties) { if ($prop.Name -match '^PS') { continue }; $startup += [pscustomobject]@{ location = $sk; name = $prop.Name; command = [string]$prop.Value } }
}
Write-JsonFile -Path (Join-Path $dirState 'startup_items.json') -Object $startup

$logInv = @()
try {
    $logInv = @(Get-WinEvent -ListLog * -ErrorAction Stop | Where-Object { $_.RecordCount -gt 0 } | Sort-Object RecordCount -Descending | ForEach-Object { [pscustomobject]@{ log = $_.LogName; recordCount = $_.RecordCount; enabled = $_.IsEnabled; sizeMB = [math]::Round($_.FileSize / 1MB, 2); lastWrite = Fmt-DateShort $_.LastWriteTime } })
    Add-Source '事件日志清单（全量）' 'ok' '' $logInv.Count
} catch { Add-Source '事件日志清单（全量）' 'denied' '枚举全部日志需要管理员（安全日志不可读时整体枚举会失败）' }
Write-JsonFile -Path (Join-Path $dirState 'event_log_inventory.json') -Object $logInv

$nativeCmds = @(
    @{ name = 'ipconfig_all.txt'; cmd = 'ipconfig'; args = @('/all') },
    @{ name = 'route_print.txt'; cmd = 'route'; args = @('print') },
    @{ name = 'arp_table.txt'; cmd = 'arp'; args = @('-a') },
    @{ name = 'netstat_ano.txt'; cmd = 'netstat'; args = @('-ano') },
    @{ name = 'netstat_statistics.txt'; cmd = 'netstat'; args = @('-s') },
    @{ name = 'netsh_tcp_global.txt'; cmd = 'netsh'; args = @('int','tcp','show','global') },
    @{ name = 'netsh_dynamicport.txt'; cmd = 'netsh'; args = @('int','ipv4','show','dynamicport','tcp') },
    @{ name = 'netsh_firewall_state.txt'; cmd = 'netsh'; args = @('advfirewall','show','allprofiles','state') },
    @{ name = 'netsh_firewall_rules.txt'; cmd = 'netsh'; args = @('advfirewall','firewall','show','rule','name=all') },
    @{ name = 'w32tm_status.txt'; cmd = 'w32tm'; args = @('/query','/status') },
    @{ name = 'w32tm_config.txt'; cmd = 'w32tm'; args = @('/query','/configuration') },
    @{ name = 'systeminfo.txt'; cmd = 'systeminfo'; args = @() },
    @{ name = 'net_session.txt'; cmd = 'net'; args = @('session') },
    @{ name = 'net_share.txt'; cmd = 'net'; args = @('share') },
    @{ name = 'net_user.txt'; cmd = 'net'; args = @('user') },
    @{ name = 'net_localgroup_admins.txt'; cmd = 'net'; args = @('localgroup','administrators') },
    @{ name = 'net_started_services.txt'; cmd = 'net'; args = @('start') },
    @{ name = 'tasklist.txt'; cmd = 'tasklist'; args = @('/v','/fo','csv') },
    @{ name = 'powercfg_lastwake.txt'; cmd = 'powercfg'; args = @('/lastwake') },
    @{ name = 'powercfg_requests.txt'; cmd = 'powercfg'; args = @('/requests') },
    @{ name = 'fsutil_dirty.txt'; cmd = 'fsutil'; args = @('dirty','query','C:') },
    @{ name = 'vssadmin_list.txt'; cmd = 'vssadmin'; args = @('list','shadows') },
    @{ name = 'wevtutil_logs.txt'; cmd = 'wevtutil'; args = @('el') }
)
$rawFiles = New-Object System.Collections.ArrayList
foreach ($nc in $nativeCmds) {
    $out = Invoke-Native $nc.cmd $nc.args
    if ($out.Count -gt 0) { Write-TextFile -Path (Join-Path $dirRaw $nc.name) -Text ($out -join "`r`n") }
    $null = $rawFiles.Add([pscustomobject]@{ file = 'raw\' + $nc.name; lines = $out.Count })
}
Add-Source '原生命令输出' 'ok' 'ipconfig/route/arp/netstat/netsh/w32tm/systeminfo/net/tasklist/powercfg/vssadmin/wevtutil' $nativeCmds.Count
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Test-Path $hostsPath) { try { Copy-Item $hostsPath (Join-Path $dirRaw 'hosts.txt') -Force -ErrorAction Stop; Add-Source 'hosts 文件' 'ok' '' 1 } catch { } }

$baseline = [ordered]@{ enabled = ($BaselineHours -gt 0); start = ''; end = ''; hours = $BaselineHours; counts = @(); note = '仅统计条数，用于事后判断某现象是否一直存在；不保存消息内容。' }
if ($BaselineHours -gt 0) {
    $baseline.start = Fmt-DateSafe $baseStart
    $baseline.end = Fmt-DateSafe $leadStart
    $cnt = @{}
    $baselineLevelFilter = @(Get-EventLevelFilter)
    foreach ($logName in @($script:QueriedLogs.Keys)) {
        $r = Get-WinEventSafe -LogName $logName -From $baseStart -To $leadStart -Level $baselineLevelFilter -MaxEvents $MaxEventsPerLog
        if (-not $r.ok) { continue }
        foreach ($e in $r.events) {
            $k = '{0}|{1}|{2}' -f $logName, $e.ProviderName, $e.Id
            if (-not $cnt.ContainsKey($k)) { $cnt[$k] = 0 }
            $cnt[$k]++
        }
    }
    $baseline.counts = @($cnt.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $seg = $_.Key -split '\|'; [pscustomobject]@{ log = $seg[0]; provider = $seg[1]; id = [int]$seg[2]; count = $_.Value } })
    Write-JsonFile -Path (Join-Path $runDir 'baseline_counts.json') -Object $baseline
    Write-Host ('      基线期组合 {0} 个' -f $baseline.counts.Count)
}

# =====================================================================
# 索引报告
# =====================================================================
$md = New-Object System.Collections.ArrayList
function Add-Md { param([string]$L = '') [void]$md.Add($L) }
Add-Md '# Windows 主机信息收集报告'
Add-Md ''
Add-Md '> 本报告只做**事实陈述**：采集了什么、范围多大、每条日志有多少条、哪些数据源不可用。'
Add-Md '> 脚本不做根因判断、不做风险定级、不给结论 —— 分析请交给 AI 或人工。'
Add-Md ''
Add-Md '## 采集顺序与目录'
Add-Md ''
Add-Md '| 顺序 | 目录 | 内容 |'
Add-Md '|---|---|---|'
Add-Md '| 01 | `01_system_events\` | 系统事件：System / Application / Setup / HardwareEvents（含关键诊断事件ID） |'
Add-Md '| 02 | `02_kernel\` | 内核/硬件相关事件通道 + 内核驱动清单 + 崩溃转储清单 + 内核与启动状态 + 防火墙丢包 |'
Add-Md '| 03 | `03_services\` | 运行服务清单 + 全部服务 + 采集时刻进程清单 |'
Add-Md '| 04 | `04_service_logs\` | 运行服务自己的事件通道 + 服务↔日志映射表 |'
Add-Md ''
Add-Md '## 一、采集范围'
Add-Md ''
Add-Md ('- **主机**：`{0}`' -f $hostLabel)
Add-Md ('- **采集时刻**：{0}（UTC {1}）' -f $hostState.collectedAt, $hostState.collectedAtUtc)
Add-Md ('- **时区**：{0}（UTC{1}）' -f $hostState.timeZone, $hostState.utcOffset)
Add-Md ('- **采集期（窗口）**：**{0} ~ {1}**（{2} 分钟）' -f (Fmt-DateShort $winStart), (Fmt-DateShort $winEnd), $winMinutes)
Add-Md ('- **前导期**：{0} ~ {1}（{2} 分钟，同样保留消息原文）' -f (Fmt-DateShort $leadStart), (Fmt-DateShort $winStart), $leadMinutes)
if ($BaselineHours -gt 0) { Add-Md ('- **基线期**：{0} ~ {1}（{2} 小时，仅统计条数）' -f (Fmt-DateShort $baseStart), (Fmt-DateShort $leadStart), $BaselineHours) }
Add-Md ('- **窗口来源**：{0}' -f $windowSource)
Add-Md ('- **故障画像**：{0}（蓝屏={1}；黑屏={2}；服务Down={3}）' -f $IncidentProfile, $includeBlueScreen, $includeBlackScreen, $includeServiceDown)
Add-Md '- **时间语义**：事件日志按指定窗口采集；服务、进程、驱动和网络等清单是采集时刻快照，不代表窗口内历史状态。'
Add-Md ('- **采集级别**：{0}' -f $(if ($ErrorsOnly) { 'Critical/Error/Warning + 关键诊断事件ID' } else { '**全部标准级别（0-5）**' }))
Add-Md ('- **单条消息上限**：{0} 字符（0=不限）；**每日志上限**：{1} 条（0=不限）' -f $MaxMessageLength, $MaxEventsPerLog)
Add-Md ('- **采集账户**：{0}（管理员：{1}）' -f $hostState.account, $(if ($script:IsAdmin) { '是' } else { '否' }))
Add-Md ('- **事件 XML**：{0}' -f $(if ($IncludeXml) { '已保存' } else { '未保存（加 -IncludeXml 可保存）' }))
Add-Md ''
Add-Md '## 二、这台机器（采集时刻快照）'
Add-Md ''
if ($hostState.Contains('os')) { Add-Md ('- **操作系统**：{0} {1} Build {2} {3}' -f $hostState.os.product, $hostState.os.version, $hostState.os.build, $hostState.os.arch) }
if ($hostState.Contains('hardware')) { Add-Md ('- **硬件**：{0} {1}　BIOS {2}（{3}）' -f $hostState.hardware.manufacturer, $hostState.hardware.product, $hostState.hardware.biosVersion, $hostState.hardware.biosDate) }
if ($hostState.Contains('cpu')) { Add-Md ('- **CPU**：{0}（{1} 逻辑处理器）' -f $hostState.cpu, $hostState.logicalProcessors) }
if ($hostState.Contains('totalMemoryMB')) { Add-Md ('- **物理内存**：{0} MB' -f $hostState.totalMemoryMB) }
if ($hostState.Contains('volumes')) { foreach ($v in @($hostState.volumes)) { Add-Md ('- **卷 {0}**：{1} / {2} GB 可用（{3}）' -f $v.drive, $v.freeGB, $v.totalGB, $v.format) } }
if ($kernelState.Contains('uptimeSeconds')) { Add-Md ('- **运行时长**：{0} 秒（推算开机时间 {1}）' -f $kernelState.uptimeSeconds, $kernelState.estimatedBootTime) }
if ($hostState.Contains('timeSource')) { Add-Md ('- **时间源**：配置 {0}；当前 {1}' -f $hostState.timeSource.configured, $hostState.timeSource.current) }
Add-Md ''
Add-Md '## 三、各阶段采集到的条数'
Add-Md ''
Add-Md '| 阶段 | 日志/通道 | 条数 | 窗口期 | 前导期 | 最早 | 最晚 | 达上限 | 文件 |'
Add-Md '|---|---|---|---|---|---|---|---|---|'
foreach ($st in @($script:LogStats | Where-Object { $_.collected -gt 0 } | Sort-Object stage, log)) {
    Add-Md ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | `{8}` |' -f $st.stage, $st.log, $st.collected, $st.inWindow, $st.inLead, $st.firstEvent, $st.lastEvent, $(if ($st.capped) { '**是**' } else { '' }), $st.file)
}
$totalEvents = (@($script:LogStats | Measure-Object -Property collected -Sum).Sum)
Add-Md ('| | **合计** | **{0}** | | | | | | |' -f $totalEvents)
Add-Md ''
Add-Md ('### 02 内核：规则发现通道共 {0} 个' -f $kernelChannels.Count)
Add-Md ''
Add-Md ('- 有数据：{0} 个（写入 `02_kernel\events\`）' -f $kWithData)
Add-Md ('- 无数据：{0} 个；不可读：{1} 个（见第五节与 ``04_service_logs\_service_log_mapping.json``）' -f $kNoData.Count, $kFailed.Count)
Add-Md ('- 内核驱动：{0} 个（``02_kernel\kernel_drivers.json``，含 type/start/state/imagePath）' -f $kernelDrivers.Count)
Add-Md ('- 崩溃转储：{0} 个（``02_kernel\crash_dumps.json``，仅清单）' -f $dumpList.Count)
if ($includeBlueScreen -or $includeBlackScreen) { Add-Md ('- WER 文本报告：{0} 个（``02_kernel\wer_reports.json``）' -f $werList.Count) }
if ($IncludeCrashDumps) { Add-Md ('- 小型转储复制：{0} 个；跳过：{1} 个（``02_kernel\crash_dumps\``）' -f $dumpCopyCount, $dumpCopySkipped) }
Add-Md ''
Add-Md ('### 03 服务：运行 {0} 个 / 全部 {1} 个' -f $runningServices.Count, $allServices.Count)
Add-Md ''
Add-Md '- 运行服务明细：`03_services\running_services.json`（含 pid/映像路径/进程路径/启动时间，若可获取）'
Add-Md '- 全部服务：`03_services\all_services.json`（含 start/delayedAutoStart/serviceType/account 原始值）'
Add-Md '- 采集时刻进程：`03_services\processes.json`'
if ($includeBlackScreen) { Add-Md '- 黑屏辅助快照：`03_services\display_adapters.json` / `interactive_processes.json` / `quser.txt` / `query_session.txt`' }
if ($includeServiceDown) { Add-Md ('- 服务失败恢复策略：`03_services\service_failure_actions.json`（状态 {0}；成功 {1} / 尝试 {2}；这是采集时刻快照）' -f $failureActionSummary.status, $failureActionSummary.succeeded, $failureActionSummary.attempted) }
Add-Md ''
Add-Md '### 04 运行服务的日志'
Add-Md ''
Add-Md ('- {0} 个运行服务中，**{1} 个**匹配到了名字对应的事件通道，**{2} 个**没有' -f $runningServices.Count, @($svcMatch | Where-Object { $_.matchedChannelCount -gt 0 }).Count, $noMatchServices.Count)
Add-Md ('- 匹配到的通道共 {0} 个，其中有数据 {1} 个（写入 ``04_service_logs\``）' -f $matchedChannels.Count, $svcLogWithData.Count)
Add-Md '- 匹配规则与完整映射：`04_service_logs\_service_log_mapping.json`'
Add-Md ''
if ($svcLogWithData.Count -gt 0) {
    Add-Md '| 通道 | 提供程序 | 条数 | 文件 |'
    Add-Md '|---|---|---|---|'
    foreach ($c in ($svcLogWithData | Sort-Object count -Descending | Select-Object -First 80)) { Add-Md ('| {0} | {1} | {2} | `{3}` |' -f $c.channel, $c.provider, $c.count, $c.file) }
    Add-Md ''
}
if ($BaselineHours -gt 0) {
    Add-Md '## 四、基线期计数（仅供对比，不是异常判定）'
    Add-Md ''
    Add-Md ('统计区间：{0} ~ {1}（{2} 小时）。只统计条数，用于事后判断某个现象「是不是一直都有」。完整清单见 ``baseline_counts.json``。条数最多的 40 项：' -f (Fmt-DateShort $baseStart), (Fmt-DateShort $leadStart), $BaselineHours)
    Add-Md ''
    Add-Md '| 日志 | 提供程序 | 事件ID | 基线期条数 |'
    Add-Md '|---|---|---|---|'
    foreach ($b in (@($baseline.counts) | Select-Object -First 40)) { Add-Md ('| {0} | {1} | {2} | {3} |' -f $b.log, $b.provider, $b.id, $b.count) }
    Add-Md ''
}
Add-Md '## 五、数据源可用性（事实记录）'
Add-Md ''
Add-Md '状态：`ok` 已采集 / `partial` 部分成功 / `empty` 无数据 / `denied` 权限不足 / `missing` 日志或文件不存在 / `error` 查询失败。'
Add-Md '**状态不是 ok 的数据源，其对应结论不能从「没有数据」推导出「没有发生」。**'
Add-Md ''
Add-Md '| 数据源 | 状态 | 条数 | 说明 |'
Add-Md '|---|---|---|---|'
foreach ($s in @($script:Sources | Sort-Object status, source)) { Add-Md ('| {0} | {1} | {2} | {3} |' -f ($s.source -replace '\|', '\|'), $s.status, $(if ($s.count -ge 0) { $s.count } else { '' }), ($s.detail -replace '\|', '\|')) }
Add-Md ''
Add-Md '## 六、原始产物与快照'
Add-Md ''
Add-Md '| 文件 | 行数 |'
Add-Md '|---|---|'
foreach ($rf in $rawFiles) { Add-Md ('| `{0}` | {1} |' -f $rf.file, $rf.lines) }
Add-Md ''
Add-Md '`state\`：host_state.json / installed_software_updates.json / startup_items.json / event_log_inventory.json'
Add-Md ''
Add-Md '`02_kernel\`：kernel_channel_inventory.json / kernel_drivers.json / kernel_state.json / crash_dumps.json / driverquery.csv / bcdedit.txt / pfirewall_*.txt'
if ($includeBlueScreen -or $includeBlackScreen) { Add-Md '`02_kernel\wer_reports.json`：窗口内 WER 文本报告（可能受权限和保留策略影响）' }
Add-Md ''
Add-Md '`03_services\`：running_services.json / all_services.json / processes.json'
Add-Md ''
Add-Md '`04_service_logs\`：各通道 .jsonl / _service_log_mapping.json'
Add-Md ''
Add-Md '## 七、给分析者的说明'
Add-Md ''
Add-Md '1. 本包内**没有任何结论**，所有判断由分析者基于原文得出。'
Add-Md '2. 事件默认严格落在指定窗口；若显式设置 `-LeadMinutes`，窗口外事件会标记 `scope=lead`。消息超过上限会在文末标注。'
Add-Md '3. 每个事件字段：`scope`、`time`（本地时间带偏移）、`utc`、`log`、`level`、`levelId`、`provider`、`id`、`recordId`、`task`、`opcode`、`keywords`、`processId`、`threadId`、`user`、`props`、`propsArray`、`message`（原文）。'
Add-Md '4. 判断「是否一直存在」请对照「四、基线期计数」；跨设备比对统一到 UTC。'
Add-Md '5. 阶段 04 的匹配是**基于名字**的：服务名/显示名/映像文件名 与 通道名/提供程序名 的包含关系。名字不相关的服务不会被匹配到，这不代表它没有日志。'
Add-Md '6. 蓝屏转储、WER、黑屏显示/会话和服务失败策略属于异常画像辅助证据；当前服务/进程/显示设备仍是采集时刻快照，不能单独证明窗口内的历史状态。'
Add-Md ''
Write-TextFile -Path (Join-Path $runDir 'REPORT.md') -Text (($md) -join "`r`n")

$files = New-Object System.Collections.ArrayList
foreach ($f in @(Get-ChildItem $runDir -Recurse -File)) {
    $rel = $f.FullName.Substring($runDir.Length + 1)
    $null = $files.Add([pscustomobject]@{ file = $rel; sizeKB = [math]::Round($f.Length / 1KB, 1) })
}
$totalKB = [math]::Round((($files | Measure-Object -Property sizeKB -Sum).Sum), 1)
Write-JsonFile -Path (Join-Path $runDir 'index.json') -Object ([ordered]@{
        schemaVersion = '1.1'; collectionModel = 'window-events + current-running-service-snapshot + incident-profile-artifacts'; incidentProfile = $IncidentProfile; includeCrashDumps = $IncludeCrashDumps; host = $hostLabel; scriptVersion = $ScriptVersion; collectedAt = $hostState.collectedAt
        window = $hostState.window; lead = $hostState.lead; baseline = $hostState.baseline
        eventsTotal = $totalEvents
        logStats = @($script:LogStats)
        kernelChannels = $kernelChannels.Count
        kernelChannelsWithData = $kWithData
        kernelDrivers = $kernelDrivers.Count
        crashDumps = [ordered]@{ count = $dumpList.Count; copied = $dumpCopyCount; skipped = $dumpCopySkipped }
        werReports = $werList.Count
        runningServices = $runningServices.Count
        allServices = $allServices.Count
        serviceFailureActions = $failureActionSummary
        serviceLogMapping = [ordered]@{ matchedChannels = $matchedChannels.Count; channelsWithData = $svcLogWithData.Count; servicesWithLogs = @($svcMatch | Where-Object { $_.matchedChannelCount -gt 0 }).Count; servicesWithoutLogs = $noMatchServices.Count }
        sources = @($script:Sources)
        files = @($files); totalSizeKB = $totalKB
    })

$zipPath = ''
if (-not $NoZip) {
    try {
        $zipPath = Join-Path $OutputRoot ("WinHostForensics_{0}_{1}.zip" -f $hostLabel, $stamp)
        Compress-Archive -Path (Join-Path $runDir '*') -DestinationPath $zipPath -Force -ErrorAction Stop
    } catch { $zipPath = '' }
}

Write-Host ''
Write-Host '==================================================================' -ForegroundColor Green
Write-Host ' 采集完成（只收集，不做分析）' -ForegroundColor Green
Write-Host '==================================================================' -ForegroundColor Green
Write-Host (' 01 系统事件 : {0} 条' -f (@($script:LogStats | Where-Object { $_.stage -eq '01_system_events' } | Measure-Object -Property collected -Sum).Sum))
Write-Host (' 02 内核信息 : Kernel 通道 {0} 个（有数据 {1}）+ 内核驱动 {2} 个' -f $kernelChannels.Count, $kWithData, $kernelDrivers.Count)
Write-Host (' 03 运行服务 : 运行中 {0} 个 / 全部 {1} 个' -f $runningServices.Count, $allServices.Count)
Write-Host (' 04 服务日志 : 匹配通道 {0} 个（有数据 {1}），未匹配服务 {2} 个' -f $matchedChannels.Count, $svcLogWithData.Count, $noMatchServices.Count)
Write-Host (' 故障画像    : {0}（WER {1} 个；转储清单 {2} 个；转储复制 {3} 个）' -f $IncidentProfile, $werList.Count, $dumpList.Count, $dumpCopyCount)
Write-Host (' 事件总数    : {0} 条' -f $totalEvents)
Write-Host (' 输出目录    : {0}' -f $runDir)
Write-Host (' 索引报告    : {0}' -f (Join-Path $runDir 'REPORT.md'))
if ($zipPath) { Write-Host (' 压缩包      : {0}' -f $zipPath) }
Write-Host (' 总体积      : {0} KB' -f $totalKB)
$notOk = @($script:Sources | Where-Object { $_.status -in @('partial', 'denied', 'missing', 'error') })
if ($notOk.Count -gt 0) {
    Write-Host ''
    Write-Host ' 以下数据源未取到（已在 REPORT.md 第五节如实记录）：' -ForegroundColor Yellow
    foreach ($s in ($notOk | Select-Object -First 8)) { Write-Host ('   [{0}] {1}' -f $s.status, $s.source) -ForegroundColor DarkYellow }
    if ($notOk.Count -gt 8) { Write-Host ('   ... 共 {0} 项' -f $notOk.Count) -ForegroundColor DarkYellow }
}
Write-Host ''
