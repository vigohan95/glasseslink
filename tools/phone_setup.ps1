# phone_setup.ps1 — 一旦安卓机插上并授权 USB 调试，自动完成：代理隧道 → 装 Visor → 起 Visor → 开 7333 转发
# 用法: pwsh -File phone_setup.ps1 [-SkipInstall]
param(
  [switch]$SkipInstall,
  [int]$ProxyPort = 7897,
  [string]$Apk = "$PSScriptRoot\..\apk\visor-3.1.0.apk",
  [int]$WaitSeconds = 180
)

$ErrorActionPreference = 'Continue'
$adb = Join-Path $PSScriptRoot 'platform-tools\adb.exe'
$tmp = Join-Path $PSScriptRoot 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TMP = $tmp; $env:TEMP = $tmp; $env:HOME = $tmp

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

& $adb start-server 2>&1 | Out-Null
Say "等待已授权的真机（排除 emulator-*）..."

$serial = $null
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
  $lines = & $adb devices 2>$null
  foreach ($l in $lines) {
    if ($l -match '^(\S+)\s+device$' -and $matches[1] -notmatch '^emulator-') { $serial = $matches[1]; break }
    if ($l -match '^(\S+)\s+unauthorized$') { Say "设备 $($matches[1]) 未授权 —— 请在手机上点『允许 USB 调试』" }
  }
  if ($serial) { break }
  Start-Sleep -Seconds 3
}
if (-not $serial) { Say "超时：没有识别到已授权的真机。请确认已开『开发者选项 → USB 调试』并在弹窗点允许。"; exit 2 }

Say "设备: $serial"
& $adb -s $serial shell getprop ro.product.model
& $adb -s $serial shell getprop ro.build.version.release

# 1) 让手机借 PC 的 Clash 出网：adb reverse 把手机的 127.0.0.1:7897 隧道到 PC 的 7897
& $adb -s $serial reverse --remove-all 2>&1 | Out-Null
& $adb -s $serial reverse "tcp:$ProxyPort" "tcp:$ProxyPort" 2>&1 | Out-Null
$rev = & $adb -s $serial reverse --list
Say "reverse: $rev"
& $adb -s $serial shell settings put global http_proxy "127.0.0.1:$ProxyPort"
Say "手机系统代理已设为 127.0.0.1:$ProxyPort（走 USB 隧道，不依赖同一 WiFi）"
& $adb -s $serial shell 'echo proxy-test; command -v curl >/dev/null && curl -s -m 15 https://api.ipify.org || echo no-curl'

# 2) 装 Visor
if (-not $SkipInstall) {
  if (-not (Test-Path $Apk)) { Say "缺 APK: $Apk"; exit 3 }
  Say "安装 Visor ..."
  & $adb -s $serial install -r -g $Apk
  & $adb -s $serial install -r -g $Apk
}

# 3) 找包名并启动
$pkgs = & $adb -s $serial shell pm list packages 2>$null | Where-Object { $_ -match 'visor' }
Say "找到: $($pkgs -join ', ')"
$pkg = ($pkgs | Select-Object -First 1) -replace '^package:', ''
if ($pkg) {
  & $adb -s $serial shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null
  Say "已启动 $pkg"
}

# 4) 预留 VDK 转发（Visor 起服务后才生效，失败无所谓）
& $adb -s $serial forward tcp:7333 localabstract:visor-kit 2>&1 | Out-Null
Say "forward: $(& $adb -s $serial forward --list)"
Say "SERIAL=$serial"
