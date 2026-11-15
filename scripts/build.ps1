param([string]$DevEcoHome = $env:DEVECO_HOME)
$ErrorActionPreference = 'Stop'
if (-not $DevEcoHome) {
  $homeFile = Join-Path $env:LOCALAPPDATA 'Huawei\DevEcoStudio6.1\.home'
  if (Test-Path -LiteralPath $homeFile) { $DevEcoHome = (Get-Content -LiteralPath $homeFile -Raw).Trim() }
}
if (-not $DevEcoHome) { throw 'Pass -DevEcoHome or set DEVECO_HOME to your DevEco Studio installation.' }
$nodePath = Join-Path $DevEcoHome 'tools\node\node.exe'
$wrapperPath = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.js'
if (-not (Test-Path -LiteralPath $nodePath)) { throw "DevEco Node not found: $nodePath" }
$env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
$env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
  # 本地 HAR（native/iec）通过 ohpm 链接；首次构建或改了 har 之后都要重新安装。
  if (-not (Test-Path -LiteralPath 'entry\oh_modules\iec')) {
    $ohpm = Join-Path $DevEcoHome 'tools\ohpm\bin\ohpm.bat'
    if (-not (Test-Path -LiteralPath $ohpm)) { throw "ohpm not found: $ohpm" }
    & $ohpm install --all
    if ($LASTEXITCODE -ne 0) { throw "ohpm install failed: $LASTEXITCODE" }
  }
  & $nodePath $wrapperPath --mode module -p module=entry@default -p product=default assembleHap --no-daemon
  if ($LASTEXITCODE -ne 0) { throw "Build failed: $LASTEXITCODE" }
  Write-Output (Join-Path (Get-Location) 'entry\build\default\outputs\default\entry-default-unsigned.hap')
} finally {
  Pop-Location
}
