param(
    [ValidateSet('All', 'Windows', 'Android')]
    [string]$Platform = 'All'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Release.Common.ps1')

$missing = [System.Collections.Generic.List[string]]::new()

function Write-Check {
    param([string]$Name, [bool]$Found, [string]$Detail, [bool]$Required = $true)

    $state = if ($Found) { '可用' } elseif ($Required) { '缺失' } else { '未检测到' }
    $color = if ($Found) { 'Green' } elseif ($Required) { 'Red' } else { 'Yellow' }
    Write-Host ("[{0}] {1}: {2}" -f $state, $Name, $Detail) -ForegroundColor $color
    if (!$Found -and $Required) {
        $missing.Add($Name)
    }
}

function Find-CommandPath {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Source
}

Write-Host "DreamMangaReader 发布环境检查（$Platform，只读）"
Write-Check 'PowerShell 7' ($PSVersionTable.PSVersion.Major -ge 7) "$($PSVersionTable.PSVersion) / $($PSHOME)"

foreach ($tool in @('flutter', 'dart', 'git')) {
    $path = Find-CommandPath $tool
    $detail = if ($path) {
        $versionLine = (& $path --version 2>&1 | Select-Object -First 1)
        "$path / $versionLine"
    }
    else { 'PATH 中未找到' }
    Write-Check $tool (![string]::IsNullOrWhiteSpace($path)) $detail
}

if ($Platform -in @('All', 'Android')) {
    $javaPath = Find-CommandPath 'java'
    $javaDetail = if ($javaPath) { "$javaPath / $(& $javaPath -version 2>&1 | Select-Object -First 1)" } else { 'PATH 中未找到' }
    Write-Check 'JDK' (![string]::IsNullOrWhiteSpace($javaPath)) $javaDetail

    $sdkCandidates = @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $androidSdk = $sdkCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    $adbPath = if ($androidSdk) { Join-Path $androidSdk 'platform-tools\adb.exe' } else { '' }
    Write-Check 'Android SDK' (![string]::IsNullOrWhiteSpace($androidSdk) -and (Test-Path -LiteralPath $adbPath -PathType Leaf)) $(if ($androidSdk) { $androidSdk } else { '未找到 SDK 目录' })
}

if ($Platform -in @('All', 'Windows')) {
    $vswhereCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'),
        (Find-CommandPath 'vswhere.exe')
    ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique
    $vswhere = $vswhereCandidates | Select-Object -First 1
    $vsInstall = if ($vswhere) {
        (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
    }
    else { $null }
    Write-Check 'Visual Studio C++' (![string]::IsNullOrWhiteSpace($vsInstall)) $(if ($vsInstall) { $vsInstall } else { '未找到 C++ x64 工具集' })

    $nugetPath = Find-CommandPath 'nuget.exe'
    Write-Check 'NuGet' (![string]::IsNullOrWhiteSpace($nugetPath)) $(if ($nugetPath) { $nugetPath } else { 'PATH 中未找到 nuget.exe' })

    $innoCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Find-CommandPath 'ISCC.exe')
    ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique
    $innoPath = $innoCandidates | Select-Object -First 1
    Write-Check 'Inno Setup 6' (![string]::IsNullOrWhiteSpace($innoPath)) $(if ($innoPath) { $innoPath } else { '未找到 ISCC.exe' })
}

$tokenNames = @('DREAMMANGAREADER_GITEE_TOKEN', 'GITEE_TOKEN')
$tokenPresent = $false
foreach ($name in $tokenNames) {
    foreach ($scope in @('Process', 'User', 'Machine')) {
        if (![string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, $scope))) {
            $tokenPresent = $true
        }
    }
}
Write-Check 'Gitee Token' $tokenPresent $(if ($tokenPresent) { '已配置（值不会显示）' } else { '未配置；打包不需要，正式发布时需要' }) $false

try {
    $repo = Invoke-RestMethod -Method Get -Uri 'https://gitee.com/api/v5/repos/TypeDreamMoon/DreamMangaReader' -TimeoutSec 12
    $identityOk = [string]$repo.full_name -ieq 'TypeDreamMoon/DreamMangaReader'
    Write-Check 'Gitee 公共仓库' $identityOk "$($repo.full_name) / 默认分支 $($repo.default_branch)" $false
}
catch {
    Write-Check 'Gitee 公共仓库' $false "只读查询失败：$($_.Exception.Message)" $false
}

if ($missing.Count -gt 0) {
    Write-Host "缺少当前平台所需工具：$($missing -join '、')" -ForegroundColor Red
    exit 1
}
Write-Host '环境检查通过。' -ForegroundColor Green
