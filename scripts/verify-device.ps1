param(
  [string]$Hap = (Join-Path $PSScriptRoot '..\entry\build\default\outputs\default\entry-default-signed.hap'),
  [string]$OutDir = (Join-Path $PSScriptRoot '..\.test-build'),
  [int]$WaitSeconds = 90,
  [switch]$CleanData,
  [string]$Hdc = $env:HDC
)
# 真机验收：装、清数据、启动、等首启解包、截图、抓日志。
$ErrorActionPreference = 'Stop'
if ($Hdc) { $hdc = $Hdc }
elseif ($env:DEVECO_HOME) { $hdc = Join-Path $env:DEVECO_HOME 'sdk\default\openharmony\toolchains\hdc.exe' }
else { $hdc = 'hdc' }
$bundle = 'com.snoworwind.phoh'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$targets = & $hdc list targets
if (-not $targets -or $targets -match 'Empty') { throw '没有已连接的真机（hdc list targets 为空）' }
Write-Output "device: $targets"

& $hdc install -r $Hap | Select-Object -Last 1
& $hdc shell "aa force-stop $bundle" | Out-Null
if ($CleanData) { & $hdc shell "bm clean -n $bundle -d" | Out-Null }
& $hdc shell 'hilog -r' | Out-Null
& $hdc shell "aa start -a EntryAbility -b $bundle"
Start-Sleep -Seconds 5

for ($i = 0; $i -lt $WaitSeconds; $i += 15) {
  & $hdc shell "snapshot_display -f /data/local/tmp/verify.jpeg" | Out-Null
  & $hdc file recv /data/local/tmp/verify.jpeg (Join-Path $OutDir "verify-$i.jpeg") | Out-Null
  Write-Output "captured verify-$i.jpeg"
  Start-Sleep -Seconds 15
}

Write-Output '=== process ==='
& $hdc shell "ps -ef | grep -i phoh | grep -v grep"
Write-Output '=== sandbox ==='
& $hdc shell "du -sh /data/app/el2/100/base/$bundle/files 2>/dev/null; ls /data/app/el2/100/base/$bundle/files"
Write-Output '=== app log (last 40 lines) ==='
& $hdc shell "hilog -x | grep -iE 'phoh|dsh web' | grep -viE 'render_service|skia' | tail -40"
