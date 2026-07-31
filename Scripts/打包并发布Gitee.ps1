param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('stable', 'beta')][string]$Channel = 'stable',
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\ReleaseOutput'),
    [switch]$SkipTests,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$normalizedVersion = $Version.Trim() -replace '^v', ''

& (Join-Path $PSScriptRoot '检查发布环境.ps1') -Platform All
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& (Join-Path $PSScriptRoot '打包新版本.ps1') -Version $normalizedVersion -Channel $Channel -Platform All -OutputRoot $OutputRoot -SkipTests:$SkipTests
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$assetRoot = Join-Path ([System.IO.Path]::GetFullPath($OutputRoot)) "v$normalizedVersion\gitee"
$files = @(Get-ChildItem -LiteralPath $assetRoot -File | Sort-Object Name)
Write-Host '即将使用以下完整 All 构建进行 Gitee 发布：' -ForegroundColor Cyan
$files | Select-Object Name, Length | Format-Table -AutoSize

if ($DryRun) {
    & (Join-Path $PSScriptRoot '发布到Gitee.ps1') -AssetRoot $assetRoot -DryRun
    exit $LASTEXITCODE
}

$answer = Read-Host '确认以上 Windows + Android 完整附件后发布？输入 Y 继续'
if ($answer -cne 'Y') { throw '用户取消发布。' }
& (Join-Path $PSScriptRoot '发布到Gitee.ps1') -AssetRoot $assetRoot -ConfirmPublish
exit $LASTEXITCODE
