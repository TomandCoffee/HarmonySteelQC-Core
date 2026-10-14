<#
.SYNOPSIS
    HarmonySteelQC 应用构建脚本（支持可选签名注入）。

.DESCRIPTION
    为什么需要它：
      1) AGC 云调试只接受 release 签名的 HAP，而 release 构建对启动前的
         缓存/配置状态很敏感 —— 脚本每次先清 entry\build，规避「切换
         buildMode 后资源删除失败」（app/README.md 坑 7）。
      2) app/build-profile.json5 是被 git 跟踪的，DevEco 的签名配置会把
         证书路径和口令明文写进去。本脚本把签名材料放在 git-ignored 的
         app/signing.config.json，只在构建期间注入 build-profile.json5，
         构建结束后立刻还原，保证 git status 始终干净。

.PARAMETER Mode
    debug | release。云调试上传请用 release。

.PARAMETER Sign
    注入 app/signing.config.json 里的签名材料并签名；不加此开关则产出
    entry-default-unsigned.hap（只能用于本地自检构建是否通过）。

.PARAMETER NoClean
    跳过构建前的 entry\build 清理（默认清理）。

.PARAMETER KeepInjected
    构建后**不**还原 build-profile.json5（危险：该文件会被 git 跟踪）。

.PARAMETER Revert
    不构建，只把 build-profile.json5 的 signingConfigs 清空。
    用途：脚本被中途打断（例如输出被 `| Select-Object -First N` 截断，
    PowerShell 会直接结束子进程，finally 来不及执行）时，一条命令恢复干净状态。

.PARAMETER DevEcoStudio
    DevEco Studio 安装目录，默认 D:\DevEco Studio。

.EXAMPLE
    powershell -File app\scripts\build-hap.ps1 -Mode release
    powershell -File app\scripts\build-hap.ps1 -Mode release -Sign
    powershell -File app\scripts\build-hap.ps1 -Revert
#>
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Mode = 'release',
    [switch]$Sign,
    [switch]$NoClean,
    [switch]$KeepInjected,
    [switch]$Revert,
    [string]$DevEcoStudio = 'D:\DevEco Studio'
)

$ErrorActionPreference = 'Stop'
$buildExit = 1

# ──────────────────────────── 路径 ────────────────────────────
$appDir      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$profilePath = Join-Path $appDir 'build-profile.json5'
$configPath  = Join-Path $appDir 'signing.config.json'
$buildDir    = Join-Path $appDir 'entry\build'
$outDir      = Join-Path $buildDir 'default\outputs\default'

$nodeExe  = Join-Path $DevEcoStudio 'tools\node\node.exe'
$hvigorJs = Join-Path $DevEcoStudio 'tools\hvigor\bin\hvigorw.js'
$sdkDir   = Join-Path $DevEcoStudio 'sdk'

foreach ($p in @($nodeExe, $hvigorJs, $sdkDir)) {
    if (-not (Test-Path $p)) {
        throw "找不到 DevEco 组件：$p`n用 -DevEcoStudio 指定安装目录（当前：$DevEcoStudio）。"
    }
}

# ──────────────────────── 签名相关工具 ────────────────────────
function Get-SigningConfig {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "缺少签名配置：$Path`n请先复制 signing.config.example.json 为 signing.config.json 并填写（该文件已在 .gitignore 中排除）。"
    }
    # 去掉整行注释（ConvertFrom-Json 不认 JSON5 注释）
    $lines = Get-Content -Path $Path -Encoding UTF8 | Where-Object { $_.TrimStart() -notmatch '^//' }
    $cfg = ($lines -join "`n") | ConvertFrom-Json
    foreach ($f in @('certpath', 'profile', 'storeFile', 'storePassword', 'keyAlias', 'keyPassword')) {
        $v = $cfg.$f
        if ([string]::IsNullOrWhiteSpace($v)) { throw "signing.config.json 字段为空或缺失：$f" }
        if ($f -in @('certpath', 'profile', 'storeFile')) {
            # ⚠️ 占位符（如 <用户名>）含路径非法字符，Test-Path 会**抛异常**而不是返回 false，
            #    直接调用会让用户看到一串 PowerShell 报错。这里包一层，给出可操作的提示。
            $exists = $false
            try { $exists = Test-Path -LiteralPath $v -ErrorAction Stop } catch { $exists = $false }
            if (-not $exists) {
                throw "signing.config.json 的 $f 指向的文件不存在或路径非法：$v`n" +
                      "  · 若还没填：请把示例里的 <用户名> 等占位符替换成真实路径`n" +
                      "  · 若路径含空格/特殊字符：确认已写成双反斜杠（JSON 里 ``\`` 是转义符）"
            }
        }
    }
    return $cfg
}

function ConvertTo-JsonString {
    param([string]$Value, [string]$Field)
    # 反斜杠必须先转义，否则会把 \" 变成 \\"
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function New-SigningEntry {
    param($Cfg)
    $alg = if ($Cfg.signAlg) { $Cfg.signAlg } else { 'SHA256withECDSA' }
    $g = [string]'          '   # 10 空格缩进
    $lines = @(
        '      {',
        '        "name": "default",',
        '        "type": "HarmonyOS",',
        '        "material": {',
        ($g + '"storeFile": "{0}",'     -f (ConvertTo-JsonString $Cfg.storeFile     'storeFile')),
        ($g + '"storePassword": "{0}",' -f (ConvertTo-JsonString $Cfg.storePassword 'storePassword')),
        ($g + '"keyAlias": "{0}",'      -f (ConvertTo-JsonString $Cfg.keyAlias      'keyAlias')),
        ($g + '"keyPassword": "{0}",'   -f (ConvertTo-JsonString $Cfg.keyPassword   'keyPassword')),
        ($g + '"certpath": "{0}",'      -f (ConvertTo-JsonString $Cfg.certpath      'certpath')),
        ($g + '"profile": "{0}",'       -f (ConvertTo-JsonString $Cfg.profile       'profile')),
        ($g + '"signAlg": "{0}"'        -f $alg),
        '        }',
        '      }'
    )
    return ($lines -join "`r`n")
}

function Add-SigningToProfile {
    param([string]$Text, $Cfg)
    $key = '"signingConfigs"'
    $k = $Text.IndexOf($key)
    if ($k -lt 0) { throw "build-profile.json5 里找不到 $key 。" }
    $lb = $Text.IndexOf('[', $k)
    $rb = $Text.IndexOf(']', $lb)
    if ($lb -lt 0 -or $rb -lt 0) { throw "build-profile.json5 的 signingConfigs 不是数组，请手工检查。" }
    if ($Text.Substring($lb + 1, $rb - $lb - 1).Trim().Length -ne 0) {
        throw "build-profile.json5 的 signingConfigs 不是空数组（可能已被 DevEco 写入签名配置）。请先把它还原成 [] 再运行本脚本。"
    }
    $entry = New-SigningEntry -Cfg $Cfg
    # 纯字面量拼接：不经过正则替换，避免口令里的 $ 等字符被当成替换组
    $head = $Text.Substring(0, $lb + 1)
    $tail = $Text.Substring($rb)
    return ($head + "`r`n" + $entry + "`r`n    " + $tail)
}

function Remove-SigningFromProfile {
    param([string]$Text)
    $key = '"signingConfigs"'
    $k = $Text.IndexOf($key)
    if ($k -lt 0) { throw "build-profile.json5 里找不到 $key 。" }
    $lb = $Text.IndexOf('[', $k)
    $rb = $Text.IndexOf(']', $lb)
    if ($lb -lt 0 -or $rb -lt 0) { throw "build-profile.json5 的 signingConfigs 不是数组，请手工检查。" }
    if ($Text.Substring($lb + 1, $rb - $lb - 1).Trim().Length -eq 0) { return $Text }   # 本来就是空的
    return ($Text.Substring(0, $lb + 1) + ']' + $Text.Substring($rb + 1))
}

# ──────────────────────────── 主流程 ────────────────────────────
$original = [System.IO.File]::ReadAllText($profilePath)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$injected = $false

# -Revert：只做清理，不构建。用于脚本被中途打断后的恢复。
if ($Revert) {
    $cleaned = Remove-SigningFromProfile -Text $original
    if ($cleaned -eq $original) {
        Write-Host "[还原] signingConfigs 本来就是空的，无需处理。" -ForegroundColor DarkGray
    }
    else {
        [System.IO.File]::WriteAllText($profilePath, $cleaned, $utf8NoBom)
        Write-Host "[还原] 已清空 build-profile.json5 的 signingConfigs。" -ForegroundColor Cyan
    }
    exit 0
}

try {
    if ($Sign) {
        $cfg = Get-SigningConfig -Path $configPath
        $patched = Add-SigningToProfile -Text $original -Cfg $cfg
        [System.IO.File]::WriteAllText($profilePath, $patched, $utf8NoBom)
        $injected = $true
        Write-Host "[签名] 已注入 signingConfigs（profile=$($cfg.profile)）" -ForegroundColor Cyan
    }
    else {
        Write-Host "[签名] 未启用 -Sign，将产出未签名 HAP（仅供构建自检）" -ForegroundColor DarkGray
    }

    if (-not $NoClean) {
        if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "[清理] 已删除 entry\build（规避坑 7：切换 buildMode 时的资源删除失败）" -ForegroundColor DarkGray
    }

    $env:DEVECO_SDK_HOME = $sdkDir
    Write-Host "[构建] buildMode=$Mode  DEVECO_SDK_HOME=$sdkDir`n" -ForegroundColor DarkGray

    Push-Location $appDir
    try {
        $savedEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'      # 原生命令的 stderr 不能被当成终止错误
        & $nodeExe $hvigorJs --mode module -p product=default -p 'module=entry@default' -p "buildMode=$Mode" assembleHap --no-daemon 2>&1 | Out-Host
        $buildExit = $LASTEXITCODE
        $ErrorActionPreference = $savedEap
    }
    finally { Pop-Location }
}
finally {
    if ($injected -and -not $KeepInjected) {
        [System.IO.File]::WriteAllText($profilePath, $original, $utf8NoBom)
        Write-Host "[签名] build-profile.json5 已还原为空签名配置" -ForegroundColor Cyan
    }
    elseif ($injected -and $KeepInjected) {
        Write-Host "[签名] ⚠️ 已按 -KeepInjected 保留签名配置，提交前务必清理 build-profile.json5" -ForegroundColor Yellow
    }
}

# ──────────────────────────── 结果 ────────────────────────────
if (Test-Path $outDir) {
    Write-Host "`n产物目录：$outDir" -ForegroundColor Green
    Get-ChildItem $outDir -File | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0,-32} {1,8:N2} MB" -f $_.Name, ($_.Length / 1MB))
    }
    if ($Sign) {
        $signed = Join-Path $outDir 'entry-default-signed.hap'
        if (Test-Path $signed) {
            Write-Host "`n✅ 已签名 HAP（云调试上传这一个）：`n   $signed" -ForegroundColor Green
        }
        else {
            Write-Host "`n⚠️ 没有生成 entry-default-signed.hap —— 请检查上面的签名报错。" -ForegroundColor Yellow
        }
    }
}

if ($buildExit -ne 0) {
    Write-Host "`n❌ 构建失败（exit=$buildExit）" -ForegroundColor Red
}
else {
    Write-Host "`n✅ 构建成功（buildMode=$Mode）" -ForegroundColor Green
}
exit $buildExit
