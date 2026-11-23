# mtp_glasses.ps1 — 不走 adb，直接用 USB 的 MTP 通道读写手机共享存储
# 用法:
#   .\mtp_glasses.ps1 list [路径片段]        列 Download / Android/data 下的东西
#   .\mtp_glasses.ps1 pull <手机内相对路径> <本地目录>
#   .\mtp_glasses.ps1 push <本地文件> [手机目录名，默认 Download]
param(
  [Parameter(Mandatory = $true)][string]$Action,
  [string]$Arg1 = "",
  [string]$Arg2 = ""
)

$ErrorActionPreference = 'Continue'
$sh = New-Object -ComObject Shell.Application

function Get-DeviceItem {
  $dev = $sh.NameSpace(17).Items() | Where-Object { $_.Name -match 'MTP' -or $_.Path -match 'vid_0e8d' } | Select-Object -First 1
  if (-not $dev) { throw "没找到 MTP 设备。确认数据线插着、手机解锁、USB 用途选『文件传输』" }
  return $dev
}

function Get-Storage($dev) { return ($dev.GetFolder.Items() | Select-Object -First 1) }

function Resolve-Path2($storageItem, [string]$rel) {
  $cur = $storageItem
  foreach ($seg in ($rel -split '[\\/]' | Where-Object { $_ })) {
    $kids = $cur.GetFolder.Items() | Where-Object { $_.Name -eq $seg -or $_.Name -like "$seg*" }
    if (-not $kids) { throw "找不到段: $seg （在 $($cur.Name) 下）" }
    $cur = ($kids | Select-Object -First 1)
  }
  return $cur
}

$dev = Get-DeviceItem
$storage = Get-Storage $dev
Write-Host "device: $($dev.Name) / storage: $($storage.Name)"

switch ($Action) {
  'list' {
    $target = if ($Arg1) { Resolve-Path2 $storage $Arg1 } else { $storage }
    Write-Host "== $($target.Name) =="
    $target.GetFolder.Items() | Sort-Object Name | ForEach-Object {
      $sz = $_.ExtendedProperty('System.Size')
      if ($_.IsFolder) { "  [DIR ] $($_.Name)" } else { "  [FILE] $($_.Name)  $sz bytes" }
    }
  }
  'pull' {
    if (-not $Arg2) { throw "用法: pull <手机相对路径> <本地目录>" }
    New-Item -ItemType Directory -Force -Path $Arg2 | Out-Null
    $item = Resolve-Path2 $storage $Arg1
    $dest = $sh.NameSpace((Resolve-Path $Arg2).Path)
    $dest.CopyHere($item, 0x14)
    Start-Sleep -Seconds 2
    Write-Host "pulled -> $Arg2"
  }
  'push' {
    if (-not (Test-Path $Arg1)) { throw "本地文件不存在: $Arg1" }
    $dirName = if ($Arg2) { $Arg2 } else { 'Download' }
    $tgt = Resolve-Path2 $storage $dirName
    $tgt.GetFolder.CopyHere((Resolve-Path $Arg1).Path, 0x14)
    Start-Sleep -Seconds 2
    $tgt.GetFolder.Items() | Where-Object { $_.Name -match ([IO.Path]::GetFileNameWithoutExtension($Arg1)) } |
      ForEach-Object { Write-Host "  on phone: $($_.Name)  $($_.ExtendedProperty('System.Size')) bytes" }
  }
  default { Write-Host "未知 Action: $Action （list|pull|push）" }
}
