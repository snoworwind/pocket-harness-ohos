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
# 签名配置只在本地：signing.local.profile.json5 被 .gitignore 排除，构建时临时覆盖
# 仓库里的 build-profile.json5，构建结束（含失败）立刻还原，避免口令进入工作区提交。
$profile = Join-Path $root 'build-profile.json5'
$localProfile = Join-Path $root 'signing.local.profile.json5'
$cleanProfile = $null
try {
  if (Test-Path -LiteralPath $localProfile) {
    $cleanProfile = Get-Content -LiteralPath $profile -Raw
    Copy-Item -LiteralPath $localProfile -Destination $profile -Force
  }
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
  if ($null -ne $cleanProfile) { Set-Content -LiteralPath $profile -Value $cleanProfile -NoNewline }
  Pop-Location
}
