# start_bridge.ps1 — 手机已就绪后：开 7333 转发 → 找 token → 起 bridge → 打印 iPhone 要打开的地址
param(
  [string]$Token = "",
  [int]$Port = 8787,
  [string]$BindHostHint = ""
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent          # meta-gen2
$adb  = Join-Path $PSScriptRoot 'platform-tools\adb.exe'
$tmp  = Join-Path $PSScriptRoot 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TMP = $tmp; $env:TEMP = $tmp; $env:HOME = $tmp
$py = "C:\Users\lokla\AppData\Local\Programs\Python\Python311\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# 0) 设备
$serial = (& $adb devices | Select-String '^(\S+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Where-Object { $_ -notmatch '^emulator-' } | Select-Object -First 1)
if (-not $serial) { Say "没有已授权的真机，先跑 phone_setup.ps1"; exit 2 }
Say "device: $serial"

# 1) 转发 visor-kit
& $adb -s $serial forward --remove tcp:7333 2>&1 | Out-Null
$fwd = & $adb -s $serial forward tcp:7333 localabstract:visor-kit 2>&1
Say "forward: $fwd / $(& $adb -s $serial forward --list)"

# 2) 探测端口
$open = $false
foreach ($i in 1..20) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', 7333); $c.Close(); $open = $true; break
  } catch { Start-Sleep -Milliseconds 700 }
}
Say ("port 7333 reachable: " + $open + "  (若 false：在 Visor 里打开 Settings → 网络门/Kit 开关，再重试)")

# 3) token 自动发现（读应用外部目录里的 json/prefs 备份）
if (-not $Token) {
  $pkg = (& $adb -s $serial shell pm list packages 2>$null | Select-String 'visor' | Select-Object -First 1) -replace '^package:', ''
  $pkg = ($pkg -replace '\s', '')
  if ($pkg) {
    Say "pkg: $pkg"
    $dump = & $adb -s $serial shell "ls -R /sdcard/Android/data/$pkg/files 2>/dev/null" 2>$null
    if ($dump) { $dump | Select-Object -First 40 | ForEach-Object { "   $_" } }
    $hits = & $adb -s $serial shell "grep -rilE 'token|kit' /sdcard/Android/data/$pkg/files 2>/dev/null" 2>$null
    if ($hits) { $hits | ForEach-Object { "   hit: $_" } }
    foreach ($h in ($hits -split "`n" | Where-Object { $_ -match '\S' })) {
      $body = & $adb -s $serial shell "cat '$($h.Trim())' 2>/dev/null"
      if ($body -match '"([A-Za-z0-9_\-]{16,})"') { $Token = $matches[1]; Say "token 候选: $Token"; break }
    }
  }
}
if (-not $Token) { Say "未自动找到 token —— 请在 Visor → Settings → Network door / Visor Kit 里复制 token，用 -Token 传入" }

# 4) 起 bridge
$url = "ws://127.0.0.1:7333/rpc"
Say "starting bridge: $url  port=$Port"
$args = @("$root\bridge\server.py", "--url", $url, "--port", "$Port")
if ($Token) { $args += @("--token", $Token) }
Start-Process -FilePath $py -ArgumentList $args -WorkingDirectory "$root\bridge" -WindowStyle Minimized
Start-Sleep -Seconds 3

# 5) 打印地址
$ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)' } | Select-Object -ExpandProperty IPAddress
Say "iPhone 打开（同一 WiFi 或 PC 热点）："
foreach ($ip in $ips) { Say ("   http://{0}:{1}/" -f $ip, $Port) }
Say "自检： curl http://127.0.0.1:$Port/api/status"
