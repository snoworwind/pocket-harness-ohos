<#
  签名并安装到真机。

  用法（参数来自 AGC / DevEco 自动签名产出的那套材料）：
    pwsh -File scripts/sign-and-install.ps1 `
      -AppCert 'C:\Users\zouha\.ohos\config\default_xxx.cer' `
      -Profile  'C:\Users\zouha\.ohos\config\default_xxx.p7b' `
      -Keystore 'C:\Users\zouha\.ohos\config\default_xxx.p12' `
      -KeystorePwd '******' -KeyPwd '******' -KeyAlias 'debugKey'

  Profile 里的 bundle-name 必须等于 AppScope/app.json5 的 bundleName，
  否则安装会以签名校验失败被拒。脚本会先做这个检查，不匹配就直接退出。
#>
param(
  [Parameter(Mandatory = $true)][string]$AppCert,
  [Parameter(Mandatory = $true)][string]$Profile,
  [Parameter(Mandatory = $true)][string]$Keystore,
  [Parameter(Mandatory = $true)][string]$KeystorePwd,
  [string]$KeyPwd,
  [string]$KeyAlias = 'debugKey',
  [string]$SignAlg = 'SHA256withECDSA',
  [string]$DevEcoHome = 'D:\D Program Files\DevEco Studio',
  [string]$InHap,
  [string]$OutHap,
  [switch]$SkipInstall,
  [switch]$SkipLaunch
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not $KeyPwd) { $KeyPwd = $KeystorePwd }
if (-not $InHap) { $InHap = Join-Path $root 'entry\build\default\outputs\default\entry-default-unsigned.hap' }
if (-not $OutHap) { $OutHap = Join-Path $root 'entry\build\default\outputs\default\entry-default-signed.hap' }

foreach ($f in @($AppCert, $Profile, $Keystore, $InHap)) {
  if (-not (Test-Path -LiteralPath $f)) { throw "文件不存在：$f" }
}

$java = Join-Path $DevEcoHome 'jbr\bin\java.exe'
$signTool = Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$hdc = Join-Path $DevEcoHome 'sdk\default\openharmony\toolchains\hdc.exe'
foreach ($f in @($java, $signTool, $hdc)) {
  if (-not (Test-Path -LiteralPath $f)) { throw "找不到工具：$f" }
}

# 1. 包名 / Profile 一致性检查。p7b 是 PKCS#7，里面那段 JSON 明文可取。
$bundleName = (Get-Content -LiteralPath (Join-Path $root 'AppScope\app.json5') -Raw | ConvertFrom-Json).app.bundleName
$profileText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Profile))
$profileJson = [regex]::Match($profileText, '\{"version-name".*?"issuer":"[^"]*"\}').Value
if (-not $profileJson) { throw "无法从 $Profile 中解析出 Profile JSON。" }
$profileBundle = ($profileJson | ConvertFrom-Json).'bundle-info'.'bundle-name'
$profileType = ($profileJson | ConvertFrom-Json).type
Write-Output "bundleName（工程） : $bundleName"
Write-Output "bundle-name（Profile）: $profileBundle  [$profileType]"
if ($profileBundle -ne $bundleName) {
  throw "Profile 绑定的是 $profileBundle，工程是 $bundleName，签名后真机会拒绝安装。请先生成与 $bundleName 匹配的调试 Profile。"
}
if ($profileType -ne 'debug') { Write-Output '注意：不是 debug 类型 Profile，真机需要 release 证书链与 AGC 分发。' }

# 2. 签名
Write-Output "签名：$InHap -> $OutHap"
& $java -jar $signTool sign-app -mode localSign -keyAlias $KeyAlias -signAlg $SignAlg `
  -appCertFile $AppCert -profileFile $Profile -inFile $InHap -outFile $OutHap `
  -keystoreFile $Keystore -keystorePwd $KeystorePwd -keyPwd $KeyPwd
if ($LASTEXITCODE -ne 0) { throw "签名失败：$LASTEXITCODE" }
$signed = Get-Item -LiteralPath $OutHap
Write-Output ("签名产物：{0} （{1:N0} 字节）" -f $signed.FullName, $signed.Length)

# 3. 校验签名（本地验一遍，省得装的时候才报错）
& $java -jar $signTool verify-app -inFile $OutHap -outCertChain (Join-Path $root '.test-build\verify-chain.cer') -outProfile (Join-Path $root '.test-build\verify-profile.p7b')
Write-Output "verify-app exit=$LASTEXITCODE"

if ($SkipInstall) { return }

# 4. 安装到真机
$targets = & $hdc list targets
Write-Output "设备：$($targets -join ', ')"
if (-not $targets -or $targets -match 'Empty') { throw '没有已连接的真机（hdc list targets 为空）。' }
& $hdc install -r $OutHap
if ($LASTEXITCODE -ne 0) { throw "安装失败：$LASTEXITCODE" }

if ($SkipLaunch) { return }

# 5. 启动并确认进程活着
& $hdc shell aa start -a EntryAbility -b $bundleName
Start-Sleep -Seconds 3
& $hdc shell "ps -ef | grep -i $bundleName | grep -v grep"
Write-Output "启动完成：$bundleName"
