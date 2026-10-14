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
# v2 新增的记录类型
$repeat = @{}          # REPEATRAW
$outread = @{}         # OUTREAD <tag> kind=plain|withOutput n=.. med=..
$idleSum = @{}         # IDLESUM <tag> gapSec=.. n=.. med=..
$e2eSum = @{}          # E2ESUM n=.. decode_med=.. readback_med=.. looop_med=.. infer_med=.. nms_med=.. total_med=..
$variant = @()         # VAR variant=.. n=.. convert_med=.. readback_med=.. loop_med=..
$big = @()             # BIG img=WxH n=.. decode_med=.. convert_med=.. infer_med=.. total_med=..
$batch = @{}           # BATCH n=.. totalMs=.. avgMs=.. perSec=..

foreach ($msg in $msgs) {
    if ($msg -match '^ENV\s+(.*)$') {
        foreach ($kv in ($Matches[1] -split '\s+')) {
            $kvp = $kv -split '=', 2; if ($kvp.Count -eq 2) { $env[$kvp[0]] = $kvp[1] }
        }
    }
    elseif ($msg -match '^INIT backend=(\S+) ok=(\S+) initMs=(\d+)') {
        $init[$Matches[1]] = [pscustomobject]@{ Ok = $Matches[2]; Ms = [int]$Matches[3] }
    }
    elseif ($msg -match '^WARM (\S+) i=(\d+) infer=(-?[\d.]+)') {
        $tag = $Matches[1]
        if (-not $warm.ContainsKey($tag)) { $warm[$tag] = New-Object System.Collections.Generic.List[double] }
        $warm[$tag].Add([double]$Matches[3])
    }
    elseif ($msg -match '^STEADYRAW (\S+) values=(.*)$') {
        $steady[$Matches[1]] = Get-Nums $Matches[2]
    }
    elseif ($msg -match '^REPEATRAW (\S+) values=(.*)$') {
        $repeat[$Matches[1]] = Get-Nums $Matches[2]
    }
    elseif ($msg -match '^OUTREAD (\S+) kind=(\S+) n=(\d+) med=(-?[\d.]+)') {
        if (-not $outread.ContainsKey($Matches[1])) { $outread[$Matches[1]] = @{} }
        $outread[$Matches[1]][$Matches[2]] = [double]$Matches[4]
    }
    elseif ($msg -match '^IDLE (\S+) gapSec=([\d.]+)(?: iter=(\d+))? infer=(-?[\d.]+)') {
        if (-not $idle.ContainsKey($Matches[1])) { $idle[$Matches[1]] = @{} }
        $g = [double]$Matches[2]
        if ($idle[$Matches[1]].ContainsKey($g)) {
            # v2：同一档有多次 → 收集为数组，供中位数使用
            $cur = $idle[$Matches[1]][$g]
            if ($cur -is [double]) { $idle[$Matches[1]][$g] = @([double]$cur, [double]$Matches[4]) }
            else { $idle[$Matches[1]][$g] = @($cur) + [double]$Matches[4] }
        }
        else { $idle[$Matches[1]][$g] = [double]$Matches[4] }
    }
    elseif ($msg -match '^IDLESUM (\S+) gapSec=([\d.]+) n=(\d+) med=(-?[\d.]+)') {
        if (-not $idleSum.ContainsKey($Matches[1])) { $idleSum[$Matches[1]] = @{} }
        $idleSum[$Matches[1]][[double]$Matches[2]] = [double]$Matches[4]
    }
    elseif ($msg -match '^BLOCK round=(\d+) (\S+) .*values=(.*)$') {
        $block += [pscustomobject]@{ Round = [int]$Matches[1]; Tag = $Matches[2]; Values = (Get-Nums $Matches[3]) }
    }
    elseif ($msg -match '^E2E backend=(\S+) img=(\S+) decode=(-?[\d.]+) readback=(-?[\d.]+) loop=(-?[\d.]+) infer=(-?[\d.]+) nms=(-?[\d.]+) total=(-?[\d.]+) boxes=(\d+)') {
        $e2e += [pscustomobject]@{
            Backend = $Matches[1]; Img = $Matches[2]; Decode = [double]$Matches[3]
            Readback = [double]$Matches[4]; Loop = [double]$Matches[5]; Infer = [double]$Matches[6]
            Nms = [double]$Matches[7]; Total = [double]$Matches[8]; Boxes = [int]$Matches[9]
        }
    }
    elseif ($msg -match '^E2E img=(\S+) decode=(-?[\d.]+) readback=(-?[\d.]+) loop=(-?[\d.]+) infer=(-?[\d.]+) nms=(-?[\d.]+) total=(-?[\d.]+) boxes=(\d+)') {
        # 兼容第 2 轮（当时 E2E 只跑 nnrt，不带 backend= 字段）
        $e2e += [pscustomobject]@{
            Backend = 'nnrt'; Img = $Matches[1]; Decode = [double]$Matches[2]
            Readback = [double]$Matches[3]; Loop = [double]$Matches[4]; Infer = [double]$Matches[5]
            Nms = [double]$Matches[6]; Total = [double]$Matches[7]; Boxes = [int]$Matches[8]
        }
    }
    elseif ($msg -match '^E2ESUM backend=(\S+) n=(\d+) decode_med=(-?[\d.]+) readback_med=(-?[\d.]+) loop_med=(-?[\d.]+) infer_med=(-?[\d.]+) nms_med=(-?[\d.]+) total_med=(-?[\d.]+)') {
        $e2eSum[$Matches[1]] = @{
            N = [int]$Matches[2]; Decode = [double]$Matches[3]; Readback = [double]$Matches[4]
            Loop = [double]$Matches[5]; Infer = [double]$Matches[6]; Nms = [double]$Matches[7]
            Total = [double]$Matches[8]
        }
    }
    elseif ($msg -match '^E2ESUM n=(\d+) decode_med=(-?[\d.]+) readback_med=(-?[\d.]+) loop_med=(-?[\d.]+) infer_med=(-?[\d.]+) nms_med=(-?[\d.]+) total_med=(-?[\d.]+)') {
        $e2eSum['nnrt'] = @{
            N = [int]$Matches[1]; Decode = [double]$Matches[2]; Readback = [double]$Matches[3]
            Loop = [double]$Matches[4]; Infer = [double]$Matches[5]; Nms = [double]$Matches[6]
            Total = [double]$Matches[7]
        }
    }
    elseif ($msg -match '^VAR variant=(\d+) n=(\d+) convert_med=(-?[\d.]+) readback_med=(-?[\d.]+) loop_med=(-?[\d.]+)') {
        $variant += [pscustomobject]@{
            Variant = [int]$Matches[1]; N = [int]$Matches[2]; Convert = [double]$Matches[3]
            Readback = [double]$Matches[4]; Loop = [double]$Matches[5]
        }
    }
    elseif ($msg -match '^BIG img=(\S+) n=(\d+) decode_med=(-?[\d.]+) convert_med=(-?[\d.]+) infer_med=(-?[\d.]+) total_med=(-?[\d.]+)') {
        $big += [pscustomobject]@{
            Img = $Matches[1]; N = [int]$Matches[2]; Decode = [double]$Matches[3]
            Convert = [double]$Matches[4]; Infer = [double]$Matches[5]; Total = [double]$Matches[6]
        }
    }
    elseif ($msg -match '^BATCH n=(\d+) totalMs=(\d+) avgMs=([\d.]+) perSec=([\d.]+)') {
        $batch = @{ N = [int]$Matches[1]; TotalMs = [int]$Matches[2]; AvgMs = [double]$Matches[3]; PerSec = [double]$Matches[4] }
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
# v2 每档多次测量 → 取中位；v1 只有一个值，也走同一路径
function Median-Of($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [double] -or $v -is [int]) { return [double]$v }
    $arr = @($v | Sort-Object)
    if ($arr.Count -eq 0) { return $null }
    return [double]$arr[[int][math]::Floor($arr.Count / 2)]
}
$gaps = @()
foreach ($k in $idle.Keys) { foreach ($g in $idle[$k].Keys) { if ($gaps -notcontains $g) { $gaps += $g } } }
$gaps = $gaps | Sort-Object
if ($gaps.Count -gt 0) {
    $hdr = '  gapSec'; foreach ($k in $idle.Keys) { $hdr += ('{0,10}' -f $k) }
    Write-Host $hdr
    foreach ($g in $gaps) {
        $row = ('  {0,-6}' -f $g)
        foreach ($k in $idle.Keys) {
            if ($idle[$k].ContainsKey($g)) {
                $m = Median-Of $idle[$k][$g]
                $row += ('{0,10}' -f ([math]::Round($m, 2)))
            }
            else { $row += ('{0,10}' -f '-') }
        }
        Write-Host $row
    }
    foreach ($k in $idle.Keys) {
        $base = Median-Of $idle[$k][0.5]
        if ($null -ne $base -and $base -gt 0) {
            foreach ($g in $gaps) {
                if ($g -ne 0.5 -and $idle[$k].ContainsKey($g)) {
                    $m = Median-Of $idle[$k][$g]
                    Write-Host ("  {0}: 间隔 {1}s 相对 0.5s 慢 {2}x" -f $k, $g, [math]::Round($m / $base, 2)) -ForegroundColor DarkGray
                }
            }
        }
    }
}
if ($idleSum.Keys.Count -gt 0) {
    Write-Host '  （IDLESUM 汇总，与上表应一致）' -ForegroundColor DarkGray
    foreach ($k in $idleSum.Keys) {
        $parts = @()
        foreach ($g in ($idleSum[$k].Keys | Sort-Object)) { $parts += ("gap{0}s={1}" -f $g, [math]::Round($idleSum[$k][$g], 2)) }
        Write-Host ("    {0,-5} {1}" -f $k, ($parts -join '  '))
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

Write-Head 'P6 端到端分段（按后端分组）'
if ($e2e.Count -gt 0) {
    $backends = $e2e | Select-Object -ExpandProperty Backend | Sort-Object -Unique
    $e2eTotals = @{}
    foreach ($bk in $backends) {
        $subset = $e2e | Where-Object { $_.Backend -eq $bk }
        Write-Host ("  [{0}] n={1}" -f $bk, $subset.Count) -ForegroundColor Cyan
        Write-Host '    img                    decode readback  loop infer  nms  total boxes'
        foreach ($e in $subset) {
            Write-Host ("    {0,-20} {1,6} {2,8} {3,5} {4,5} {5,5} {6,6} {7,5}" -f `
                $e.Img, $e.Decode, $e.Readback, $e.Loop, $e.Infer, $e.Nms, $e.Total, $e.Boxes)
        }
        $tD = ($subset | Measure-Object Decode -Average).Average
        $tR = ($subset | Measure-Object Readback -Average).Average
        $tL = ($subset | Measure-Object Loop -Average).Average
        $tI = ($subset | Measure-Object Infer -Average).Average
        $tN = ($subset | Measure-Object Nms -Average).Average
        $tT = ($subset | Measure-Object Total -Average).Average
        $e2eTotals[$bk] = @{ Infer = $tI; Total = $tT }
        if ($tT -gt 0) {
            Write-Host ("    平均：decode {0} / readback {1} / loop {2} / infer {3} / nms {4} / total {5} ms" -f `
                [math]::Round($tD, 2), [math]::Round($tR, 2), [math]::Round($tL, 2), `
                [math]::Round($tI, 2), [math]::Round($tN, 2), [math]::Round($tT, 2))
            Write-Host ("    占比：decode {0}%  readback {1}%  loop {2}%  infer {3}%  nms {4}%" -f `
                [math]::Round($tD / $tT * 100, 1), [math]::Round($tR / $tT * 100, 1), `
                [math]::Round($tL / $tT * 100, 1), [math]::Round($tI / $tT * 100, 1), `
                [math]::Round($tN / $tT * 100, 1)) -ForegroundColor Green
        }
    }
    # ★ 研究问题直答：同机同图下 NPU 相对 CPU 的端到端加速比
    if ($e2eTotals.ContainsKey('nnrt') -and $e2eTotals.ContainsKey('cpu')) {
        $n = $e2eTotals['nnrt']; $c = $e2eTotals['cpu']
        if ($n.Total -gt 0 -and $c.Total -gt 0) {
            Write-Host ''
            Write-Host ("  ★ 端到端加速比（同机同图）：nnrt {0} ms vs cpu {1} ms → 总耗时快 {2}x" -f `
                [math]::Round($n.Total, 2), [math]::Round($c.Total, 2), [math]::Round($c.Total / $n.Total, 2)) -ForegroundColor Yellow
            Write-Host ("     其中纯推理段：nnrt {0} ms vs cpu {1} ms → {2}x（推理段快，但前后处理把差距摊薄）" -f `
                [math]::Round($n.Infer, 2), [math]::Round($c.Infer, 2), [math]::Round($c.Infer / [math]::Max(0.01, $n.Infer), 2)) -ForegroundColor Yellow
        }
    }
}
if ($e2eSum.Count -gt 0) {
    foreach ($bk in $e2eSum.Keys) {
        $s = $e2eSum[$bk]
        Write-Host ("  E2ESUM[{0}] 中位：decode {1} / readback {2} / loop {3} / infer {4} / nms {5} / total {6}（n={7}）" -f `
            $bk, $s.Decode, $s.Readback, $s.Loop, $s.Infer, $s.Nms, $s.Total, $s.N) -ForegroundColor Green
    }
}

if ($variant.Count -gt 0) {
    Write-Host ''
    Write-Host '  前处理实现变体对比（同机同图交错，取中位）：' -ForegroundColor Cyan
    Write-Host '    variant  n    convert   readback   loop'
    foreach ($v in ($variant | Sort-Object Variant)) {
        Write-Host ("    {0,-8} {1,3} {2,10} {3,10} {4,6}" -f $v.Variant, $v.N, $v.Convert, $v.Readback, $v.Loop)
    }
    $base = $variant | Where-Object { $_.Variant -eq 0 }
    foreach ($v in ($variant | Where-Object { $_.Variant -ne 0 })) {
        if ($base -and $base.Convert -gt 0) {
            $gain = [math]::Round(($base.Convert - $v.Convert) / $base.Convert * 100, 1)
            Write-Host ("    变体{0} 相对变体0 省 {1}% （convert {2} → {3} ms）" -f `
                $v.Variant, $gain, $base.Convert, $v.Convert) -ForegroundColor Yellow
        }
    }
}

if ($outread.Keys.Count -gt 0) {
    Write-Host ''
    Write-Host '  P2b 输出读取口径对照（判定 predict 是否"真算完才 resolve"）：' -ForegroundColor Cyan
    foreach ($k in $outread.Keys) {
        $p = $outread[$k]['plain']
        $w = $outread[$k]['withOutput']
        if ($null -ne $p -and $null -ne $w) {
            $diff = [math]::Round($w - $p, 2)
            $flag = if ([math]::Abs($diff) -le [math]::Max(0.5, $p * 0.15)) { '一致 → 计时可信' } else { '差异明显 → 只测 Promise 会低估' }
            Write-Host ("    {0,-5} 只等Promise {1,7} ms   读输出 {2,7} ms   差 {3,6} ms   {4}" -f $k, $p, $w, $diff, $flag) -ForegroundColor Green
        }
    }
}

if ($big.Count -gt 0) {
    Write-Host ''
    Write-Host '  P9 大图端到端（量化取图分辨率的代价）：' -ForegroundColor Cyan
    Write-Host '    img           n   decode  convert   infer   total'
    foreach ($b in $big) {
        Write-Host ("    {0,-12} {1,3} {2,8} {3,8} {4,8} {5,8}" -f $b.Img, $b.N, $b.Decode, $b.Convert, $b.Infer, $b.Total)
    }
}

if ($batch.Count -gt 0) {
    Write-Host ''
    Write-Host ("  P10 批量吞吐：{0} 张共 {1} ms，平均 {2} ms/张，{3} 张/秒" -f `
        $batch.N, $batch.TotalMs, $batch.AvgMs, $batch.PerSec) -ForegroundColor Cyan
    Write-Host '    （README 声明为"50 张共 1.77 s，平均 35 ms/张"，可据此核对）' -ForegroundColor DarkGray
}

if ($repeat.Keys.Count -gt 0) {
    Write-Host ''
    Write-Host '  P11 会话内稳态复测（检验可重复性）：' -ForegroundColor Cyan
    foreach ($k in $repeat.Keys) {
        $s1 = Get-Stat $steady[$k]
        $s2 = Get-Stat $repeat[$k]
        if ($null -ne $s1 -and $null -ne $s2) {
            $drift = if ($s1.Med -gt 0) { [math]::Round(($s2.Med - $s1.Med) / $s1.Med * 100, 1) } else { 0 }
            Write-Host ("    {0,-5} 首次 med {1} ms → 复测 med {2} ms （漂移 {3}%）" -f $k, $s1.Med, $s2.Med, $drift) -ForegroundColor Green
        }
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
