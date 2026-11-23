# retry_pair.ps1 — 盯着 Visor 的配对失败页，自动点「重试」直到连上
param([int]$MaxTries = 12, [int]$IntervalSec = 20)
$adb = Join-Path $PSScriptRoot 'platform-tools\adb.exe'
$tmp = Join-Path $PSScriptRoot 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:TMP = $tmp; $env:TEMP = $tmp; $env:HOME = $tmp
$S = 'SM02E4072814739'

function Dump {
  & $adb -s $S shell uiautomator dump /sdcard/_u.xml 2>&1 | Out-Null
  & $adb -s $S pull /sdcard/_u.xml "$tmp\_u.xml" 2>&1 | Out-Null
  if (Test-Path "$tmp\_u.xml") { return [IO.File]::ReadAllText("$tmp\_u.xml", [Text.Encoding]::UTF8) }
  return ''
}

for ($i = 1; $i -le $MaxTries; $i++) {
  $ui = Dump
  if ($ui -match '未完成设置') {
    Write-Host "[$i] 失败页 -> 点重试"
    & $adb -s $S shell input tap 780 2482 | Out-Null
    Start-Sleep -Seconds $IntervalSec
  }
  elseif ($ui -match '配对模式|可以配对|已与本手机配对') {
    Write-Host "[$i] 回到选择页 -> 点设备行"
    & $adb -s $S shell input tap 560 1750 | Out-Null
    Start-Sleep -Seconds $IntervalSec
  }
  else {
    Write-Host "[$i] 状态变化，停止重试。片段："
    ($ui -split '><' | Where-Object { $_ -match 'text="[^"]{2,}"' } | ForEach-Object { if ($_ -match 'text="([^"]+)"') { $matches[1] } } | Select-Object -First 12) -join ' | '
    break
  }
}
