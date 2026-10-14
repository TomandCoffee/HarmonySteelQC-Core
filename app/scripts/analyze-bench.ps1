<#
.SYNOPSIS
    HarmonySteelQC 端侧基准测试日志分析器。

.DESCRIPTION
    读取应用「基准测试」套件输出的 hilog（TAG = STEELQC_BENCH），
    解析成可直接进报告的表：预热曲线、稳态统计、空闲衰减、
    交错块配对、端到端分段、后端一致性、CPU 线程敏感性。

    输入可以是：
      · 直接 `hilog -x -T STEELQC_BENCH` 的完整输出（带 hilog 前缀也行）
      · 只有消息体的纯文本
    解析器会同时兼容两种写法。

.PARAMETER LogPath
    日志文件路径。y

.PARAMETER ShowRaw
    额外打印各阶段的原始值序列（默认只打印汇总，避免刷屏）。

.EXAMPLE
    powershell -File app\scripts\analyze-bench.ps1 -LogPath bench.log
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LogPath,
    [switch]$ShowRaw
)

if (-not (Test-Path $LogPath)) { throw "找不到日志文件：$LogPath" }

# ──────────────────────────── 解析 ────────────────────────────
$msgs = New-Object System.Collections.Generic.List[string]
foreach ($line in (Get-Content -Path $LogPath -Encoding UTF8)) {
    $m = [regex]::Match($line, 'STEELQC_BENCH:\s*(.*)$')
    if ($m.Success) { $msgs.Add($m.Groups[1].Value.Trim()) }
    elseif ($line.Trim().Length -gt 0 -and $line -match 'BENCH|WARM|STEADY|IDLE |BLOCK|CONS|THREAD|E2E ') {
        $msgs.Add($line.Trim())
    }
}
if ($msgs.Count -eq 0) { throw "日志里没有 STEELQC_BENCH 内容（确认抓的是 hilog -x -T STEELQC_BENCH）" }

function Get-Nums([string]$s) {
    $out = New-Object System.Collections.Generic.List[double]
    foreach ($p in ($s -split ',')) {
        $t = $p.Trim()
        if ($t.Length -gt 0 -and $t -match '^-?\d+(\.\d+)?$') { $out.Add([double]$t) }
    }
    return $out.ToArray()
}

function Get-Stat($values) {
    $v = @($values | Where-Object { $_ -ge 0 } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $n = $v.Count
    $sum = 0.0; foreach ($x in $v) { $sum += $x }
    $med = if ($n % 2 -eq 1) { $v[[int](($n - 1) / 2)] } else { ($v[$n / 2 - 1] + $v[$n / 2]) / 2 }
    $p = { param($q) $idx = [int][math]::Floor($q * ($n - 1)); $v[$idx] }
    return [pscustomobject]@{
        N = $n; Min = $v[0]; P10 = (& $p 0.10); Med = $med; Mean = [math]::Round($sum / $n, 2)
        P90 = (& $p 0.90); Max = $v[$n - 1]
    }
}

$env = @{}; $init = @{}; $warm = @{}; $steady = @{}; $idle = @{}
$block = @(); $e2e = @(); $cons = @(); $consSum = @{}; $thread = @()

foreach ($msg in $msgs) {
    if ($msg -match '^ENV\s+(.*)$') {
        foreach ($kv in ($Matches[1] -split '\s+')) {
            $kvp = $kv -split '=', 2; if ($kvp.Count -eq 2) { $env[$kvp[0]] = $kvp[1] }
        }
    }
    elseif ($msg -match '^INIT backend=(\S+) ok=(\S+) initMs=(\d+)') {
        $init[$Matches[1]] = [pscustomobject]@{ Ok = $Matches[2]; Ms = [int]$Matches[3] }
    }
    elseif ($msg -match '^WARM (\S+) i=(\d+) infer=(-?\d+)') {
        $tag = $Matches[1]
        if (-not $warm.ContainsKey($tag)) { $warm[$tag] = New-Object System.Collections.Generic.List[double] }
        $warm[$tag].Add([double]$Matches[3])
    }
    elseif ($msg -match '^STEADYRAW (\S+) values=(.*)$') {
        $steady[$Matches[1]] = Get-Nums $Matches[2]
    }
    elseif ($msg -match '^IDLE (\S+) gapSec=([\d.]+) infer=(-?\d+)') {
        if (-not $idle.ContainsKey($Matches[1])) { $idle[$Matches[1]] = @{} }
        $idle[$Matches[1]][[double]$Matches[2]] = [double]$Matches[3]
    }
    elseif ($msg -match '^BLOCK round=(\d+) (\S+) .*values=(.*)$') {
        $block += [pscustomobject]@{ Round = [int]$Matches[1]; Tag = $Matches[2]; Values = (Get-Nums $Matches[3]) }
    }
    elseif ($msg -match '^E2E img=(\S+) decode=(-?\d+) convert=(-?\d+) infer=(-?\d+) nms=(-?\d+) total=(-?\d+) boxes=(\d+)') {
        $e2e += [pscustomobject]@{
            Img = $Matches[1]; Decode = [int]$Matches[2]; Convert = [int]$Matches[3]
            Infer = [int]$Matches[4]; Nms = [int]$Matches[5]; Total = [int]$Matches[6]; Boxes = [int]$Matches[7]
        }
    }
    elseif ($msg -match '^CONS img=(\S+) same=(\S+) A=(.*) B=(.*)$') {
        $cons += [pscustomobject]@{ Img = $Matches[1]; Same = $Matches[2]; A = $Matches[3]; B = $Matches[4] }
    }
    elseif ($msg -match '^CONSSUM images=(\d+) mismatch=(\d+) rate=(\S+)') {
        $consSum = @{ Images = [int]$Matches[1]; Mismatch = [int]$Matches[2]; Rate = $Matches[3] }
    }
    elseif ($msg -match '^THREAD threads=(\d+) .*values=(.*)$') {
        $thread += [pscustomobject]@{ Threads = [int]$Matches[1]; Values = (Get-Nums $Matches[2]) }
    }
}

function Write-Head([string]$t) { Write-Host ''; Write-Host "── $t " -NoNewline -ForegroundColor Cyan; Write-Host ('─' * [math]::Max(4, 60 - $t.Length)) -ForegroundColor DarkGray }

# ──────────────────────────── 报告 ────────────────────────────
Write-Host '════════ HarmonySteelQC 基准测试分析 ════════' -ForegroundColor Yellow

Write-Head '环境 / 初始化'
if ($env.Count -gt 0) { Write-Host ("  {0}" -f (($env.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  ')) }
foreach ($k in $init.Keys) { Write-Host ("  INIT {0,-5} ok={1}  {2} ms" -f $k, $init[$k].Ok, $init[$k].Ms) }

Write-Head 'P2 预热曲线（纯推理 ms，逐次）'
if ($warm.Count -gt 0) {
    $maxN = 0; foreach ($k in $warm.Keys) { if ($warm[$k].Count -gt $maxN) { $maxN = $warm[$k].Count } }
    $hdr = '  i  '; foreach ($k in $warm.Keys) { $hdr += ('{0,10}' -f $k) }
    Write-Host $hdr
    for ($i = 0; $i -lt $maxN; $i++) {
        $row = ('  {0,-3}' -f ($i + 1))
        foreach ($k in $warm.Keys) { $row += if ($i -lt $warm[$k].Count) { '{0,10}' -f $warm[$k][$i] } else { '{0,10}' -f '-' } }
        Write-Host $row
    }
}

Write-Head 'P3 稳态（连续调用）'
foreach ($k in $steady.Keys) {
    $s = Get-Stat $steady[$k]
    if ($null -eq $s) { continue }
    Write-Host ("  {0,-5} n={1}  min={2}  p10={3}  med={4}  mean={5}  p90={6}  max={7}" -f `
        $k, $s.N, $s.Min, $s.P10, $s.Med, $s.Mean, $s.P90, $s.Max)
    $jitter = if ($s.Med -gt 0) { [math]::Round(($s.Max - $s.Min) / $s.Med * 100, 1) } else { 0 }
    Write-Host ("        抖动幅度 (max-min)/med = {0}%   ← 判定阈值的噪声本底参考" -f $jitter) -ForegroundColor DarkGray
    if ($ShowRaw) { Write-Host ("        raw: " + ($steady[$k] -join ',')) -ForegroundColor DarkGray }
}

Write-Head 'P4 空闲间隔衰减（间隔 → 纯推理 ms）'
$gaps = @()
foreach ($k in $idle.Keys) { foreach ($g in $idle[$k].Keys) { if ($gaps -notcontains $g) { $gaps += $g } } }
$gaps = $gaps | Sort-Object
if ($gaps.Count -gt 0) {
    $hdr = '  gapSec'; foreach ($k in $idle.Keys) { $hdr += ('{0,10}' -f $k) }
    Write-Host $hdr
    foreach ($g in $gaps) {
        $row = ('  {0,-6}' -f $g)
        foreach ($k in $idle.Keys) { $row += if ($idle[$k].ContainsKey($g)) { '{0,10}' -f $idle[$k][$g] } else { '{0,10}' -f '-' } }
        Write-Host $row
    }
    foreach ($k in $idle.Keys) {
        $base = $idle[$k][0.5]
        if ($null -ne $base -and $base -gt 0) {
            foreach ($g in $gaps) {
                if ($g -ne 0.5 -and $idle[$k].ContainsKey($g)) {
                    Write-Host ("  {0}: 间隔 {1}s 相对 0.5s 慢 {2}x" -f $k, $g, [math]::Round($idle[$k][$g] / $base, 2)) -ForegroundColor DarkGray
                }
            }
        }
    }
}

Write-Head 'P5 交错块配对（每块 20 次）'
if ($block.Count -gt 0) {
    Write-Host '  round  backend   n   min   med   max   mean'
    foreach ($b in $block) {
        $s = Get-Stat $b.Values
        if ($null -eq $s) { continue }
        Write-Host ("  {0,-6} {1,-8} {2,3} {3,5} {4,5} {5,5} {6,7}" -f $b.Round, $b.Tag, $s.N, $s.Min, $s.Med, $s.Max, $s.Mean)
    }
    $rounds = $block | Select-Object -ExpandProperty Round | Sort-Object -Unique
    foreach ($r in $rounds) {
        $a = $block | Where-Object { $_.Round -eq $r -and $_.Tag -eq 'nnrt' }
        $c = $block | Where-Object { $_.Round -eq $r -and $_.Tag -eq 'cpu' }
        if ($a -and $c) {
            $sa = Get-Stat $a.Values; $sc = Get-Stat $c.Values
            if ($null -ne $sa -and $null -ne $sc -and $sc.Med -gt 0) {
                Write-Host ("  第{0}轮配对：nnrt {1} ms vs cpu {2} ms → nnrt 快 {3}x" -f `
                    $r, $sa.Med, $sc.Med, [math]::Round($sc.Med / $sa.Med, 2)) -ForegroundColor Green
            }
        }
    }
}

Write-Head 'P6 端到端分段（nnrt）'
if ($e2e.Count -gt 0) {
    Write-Host '  img                      decode convert infer  nms  total  boxes'
    foreach ($e in $e2e) {
        Write-Host ("  {0,-24} {1,6} {2,7} {3,5} {4,5} {5,6} {6,6}" -f $e.Img, $e.Decode, $e.Convert, $e.Infer, $e.Nms, $e.Total, $e.Boxes)
    }
    $tD = ($e2e | Measure-Object Decode -Average).Average
    $tC = ($e2e | Measure-Object Convert -Average).Average
    $tI = ($e2e | Measure-Object Infer -Average).Average
    $tN = ($e2e | Measure-Object Nms -Average).Average
    $tT = ($e2e | Measure-Object Total -Average).Average
    if ($tT -gt 0) {
        Write-Host ''
        Write-Host ("  平均占比：decode {0}%  convert {1}%  infer {2}%  nms {3}%" -f `
            [math]::Round($tD / $tT * 100, 1), [math]::Round($tC / $tT * 100, 1), `
            [math]::Round($tI / $tT * 100, 1), [math]::Round($tN / $tT * 100, 1)) -ForegroundColor Green
        Write-Host ("  推理只占 {0}% —— 优化靶子应据此确定" -f [math]::Round($tI / $tT * 100, 1)) -ForegroundColor DarkGray
    }
}

Write-Head 'P7 后端一致性'
if ($cons.Count -gt 0 -or $consSum.Count -gt 0) {
    if ($consSum.Count -gt 0) {
        Write-Host ("  样本 {0} 张，不一致 {1} 张，不一致率 {2}" -f $consSum.Images, $consSum.Mismatch, $consSum.Rate) -ForegroundColor Green
    }
    elseif ($cons.Count -gt 0) {
        Write-Host ("  逐图比对 {0} 张（日志里没有 CONSSUM 汇总行）" -f $cons.Count) -ForegroundColor DarkGray
    }
    $bad = $cons | Where-Object { $_.Same -ne 'true' }
    if ($bad) {
        Write-Host '  不一致清单：' -ForegroundColor Yellow
        foreach ($b in $bad) { Write-Host ("    {0}`n      nnrt: {1}`n      cpu : {2}" -f $b.Img, $b.A, $b.B) }
    }
    else { Write-Host '  全部样本两后端结果一致（框数 + 类别序列相同）' }
    if ($ShowRaw) { foreach ($c in $cons) { Write-Host ("    {0} same={1} A={2} B={3}" -f $c.Img, $c.Same, $c.A, $c.B) -ForegroundColor DarkGray } }
}

Write-Head '墙钟交叉校验（独立通道：用日志时间戳反推每次推理）'
# 目的：套件里的耗时是**自报**的（Date.now() 差值，1 ms 粒度）。
# 这里用 hilog 时间戳这条独立通道，反推每个阶段的单次耗时，
# 与自报值对照 —— 两者一致才说明计时可信（2026-10-14 首次使用即验证通过）。
$ts = New-Object System.Collections.Generic.List[object]
foreach ($line in (Get-Content -Path $LogPath -Encoding UTF8)) {
    $m = [regex]::Match($line, '^(\d\d-\d\d \d\d:\d\d:\d\d\.\d\d\d).*STEELQC_BENCH:\s*(.*)$')
    if ($m.Success) {
        $ts.Add([pscustomobject]@{
            T = [datetime]::ParseExact($m.Groups[1].Value, 'MM-dd HH:mm:ss.fff', $null)
            Msg = $m.Groups[2].Value
        })
    }
}
if ($ts.Count -lt 2) {
    Write-Host '  日志里没有可解析的时间戳前缀，跳过（需要带 hilog 前缀的原始输出）' -ForegroundColor DarkGray
}
else {
    Write-Host '  相邻阶段的时间差 → 反推单次耗时，并与自报值对照：'
    for ($i = 1; $i -lt $ts.Count; $i++) {
        $prev = $ts[$i - 1].Msg
        $cur = $ts[$i].Msg
        $dt = ($ts[$i].T - $ts[$i - 1].T).TotalMilliseconds

        # ⚠️ 每次 -match 都会覆盖 $Matches，所以必须立刻把捕获组取出来，
        #    不能在两处 -match 之后再引用 $Matches（这是本段第一版的 bug）。
        $mSteady = [regex]::Match($cur, '^STEADY (\S+) n=(\d+)')
        $mBlock = [regex]::Match($cur, '^BLOCK round=(\d+) (\S+) n=(\d+)')
        $mIdle = [regex]::Match($cur, '^IDLE (\S+) gapSec=([\d.]+) infer=(\d+)')

        if ($mSteady.Success) {
            # STEADY 汇总行是**循环结束后**才打印的 → dt(上一条 → 本条) 覆盖了这一阶段全部 n 次
            $tag = $mSteady.Groups[1].Value
            $n = [int]$mSteady.Groups[2].Value
            $self = Get-Stat $steady[$tag]
            $medTxt = if ($null -ne $self) { $self.Med } else { '?' }
            Write-Host ("    稳态   {0,-5} {1,2} 次：墙钟 {2,6:N0} ms → {3,5:N2} ms/次（自报中位 {4}）" -f `
                $tag, $n, $dt, ($dt / $n), $medTxt) -ForegroundColor Green
        }
        elseif ($mBlock.Success) {
            $round = [int]$mBlock.Groups[1].Value
            $tag = $mBlock.Groups[2].Value
            $n = [int]$mBlock.Groups[3].Value
            $vals = $null
            foreach ($b in $block) {
                if ($b.Round -eq $round -and $b.Tag -eq $tag) { $vals = $b.Values }
            }
            $self = Get-Stat $vals
            $meanTxt = if ($null -ne $self) { $self.Mean } else { '?' }
            Write-Host ("    交错块 {0,-5} {1,2} 次：墙钟 {2,6:N0} ms → {3,5:N2} ms/次（自报均值 {4}）" -f `
                $tag, $n, $dt, ($dt / $n), $meanTxt) -ForegroundColor Green
        }
        elseif ($mIdle.Success -and $prev.StartsWith('IDLE ')) {
            # 空闲档：dt 应等于 本档间隔 + 本次推理 + 日志开销
            $gap = [double]$mIdle.Groups[2].Value
            $inf = [int]$mIdle.Groups[3].Value
            $resid = $dt - $gap * 1000
            Write-Host ("    空闲   {0,-5} gap={1,5}s：墙钟 {2,8:N0} ms；扣掉间隔后残差 {3,5:N0} ms（自报推理 {4} ms + 日志开销）" -f `
                $mIdle.Groups[1].Value, $gap, $dt, $resid, $inf) -ForegroundColor Green
        }
    }
}

Write-Head 'P8 CPU 线程敏感性'
if ($thread.Count -gt 0) {
    Write-Host '  threads   n   min   med   max   mean'
    foreach ($t in ($thread | Sort-Object Threads)) {
        $s = Get-Stat $t.Values
        if ($null -eq $s) { continue }
        Write-Host ("  {0,-8} {1,3} {2,5} {3,5} {4,5} {5,7}" -f $t.Threads, $s.N, $s.Min, $s.Med, $s.Max, $s.Mean)
    }
}

Write-Host ''
Write-Host '════════ 分析结束 ════════' -ForegroundColor Yellow
