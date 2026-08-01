param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('stable', 'beta')][string]$Channel = 'stable',
    [ValidateSet('All', 'Windows', 'Android')][string]$Platform = 'All',
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\ReleaseOutput'),
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputRootFull = [System.IO.Path]::GetFullPath($OutputRoot)
. (Join-Path $PSScriptRoot 'Release.Common.ps1')

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)

    Write-Host "==> $Name" -ForegroundColor Cyan
    & $Action
    if ($LASTEXITCODE -ne 0) {
        throw "$Name 失败，exit code $LASTEXITCODE"
    }
}

function Reset-VersionOutput {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $fullPath))
    if ($parent.TrimEnd('\') -ne $outputRootFull.TrimEnd('\')) {
        throw "拒绝清理 OutputRoot 外的目录：$fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $fullPath | Out-Null
}

function Get-AndroidSdkRoot {
    $candidates = @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $root = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -First 1
    if (!$root) { throw '找不到 Android SDK。请先运行 Scripts/检查发布环境.ps1 -Platform Android。' }
    return $root
}

function Get-AndroidBuildTool {
    param([Parameter(Mandatory)][string]$Name)

    $buildToolsRoot = Join-Path (Get-AndroidSdkRoot) 'build-tools'
    $tool = Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
        Sort-Object { [version]$_.Name } -Descending |
        ForEach-Object { Join-Path $_.FullName $Name } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if (!$tool) { throw "Android SDK 缺少 $Name。" }
    return $tool
}

function Get-ApkMetadata {
    param([Parameter(Mandatory)][string]$Path)

    $aapt2 = Get-AndroidBuildTool 'aapt2.exe'
    $badging = & $aapt2 dump badging $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "aapt2 无法读取 APK：$Path" }
    $packageLine = @($badging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1)
    if ($packageLine.Count -eq 0 -or
        $packageLine[0] -notmatch "name='([^']+)'\s+versionCode='(\d+)'\s+versionName='([^']+)'") {
        throw "APK 包信息无法解析：$Path"
    }
    $packageName = $Matches[1]
    $versionCode = [int]$Matches[2]
    $versionName = $Matches[3]

    $apksigner = Get-AndroidBuildTool 'apksigner.bat'
    $certOutput = & $apksigner verify --print-certs $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "APK 签名校验失败：$Path" }
    $certLine = @($certOutput | Where-Object { $_ -match 'certificate SHA-256 digest:' } | Select-Object -First 1)
    if ($certLine.Count -eq 0 -or $certLine[0] -notmatch 'digest:\s*([0-9a-fA-F]{64})') {
        throw "APK 签名摘要无法解析：$Path"
    }
    return [pscustomobject]@{
        Path = $Path
        PackageName = $packageName
        VersionCode = $versionCode
        VersionName = $versionName
        CertificateSha256 = $Matches[1].ToLowerInvariant()
    }
}

function Get-KeystoreCertificateSha256 {
    $keytool = Get-Command keytool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$keytool) { throw 'PATH 中未找到 keytool.exe。' }
    $keystore = Join-Path $repoRoot 'android\app\dmr-release.jks'
    $output = & $keytool.Source -list -v -keystore $keystore -storepass dreammangareader -alias dmr 2>&1
    if ($LASTEXITCODE -ne 0) { throw '无法读取固定 Android 发布签名。' }
    $line = @($output | Where-Object { $_ -match '^\s*SHA256:' } | Select-Object -First 1)
    if ($line.Count -eq 0 -or $line[0] -notmatch 'SHA256:\s*([0-9A-Fa-f:]+)') {
        throw '无法解析固定 Android 发布证书 SHA-256。'
    }
    return ($Matches[1] -replace ':', '').ToLowerInvariant()
}

function Find-InnoCompiler {
    $innoCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $innoCommandPath = if ($innoCommand) { $innoCommand.Source } else { $null }
    $candidates = @(
        $env:DREAMMANGAREADER_ISCC,
        (Join-Path $repoRoot '.tools\inno\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        $innoCommandPath
    ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }
    $result = $candidates | Select-Object -First 1
    if (!$result) {
        throw '找不到 Inno Setup 6（ISCC.exe）。可设置 DREAMMANGAREADER_ISCC 指向旁路安装。'
    }
    return $result
}

function Assert-NuGetPresent {
    $nugetCommand = Get-Command nuget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $nugetCommandPath = if ($nugetCommand) { $nugetCommand.Source } else { $null }
    $candidates = @(
        $env:DREAMMANGAREADER_NUGET,
        (Join-Path $repoRoot '.tools\nuget.exe'),
        $nugetCommandPath
    ) | Where-Object { ![string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }
    if (!($candidates | Select-Object -First 1)) {
        throw '找不到 NuGet。可将 nuget.exe 放到仓库 .tools\nuget.exe，或设置 DREAMMANGAREADER_NUGET。'
    }
}

function Assert-VisualStudioAtlPresent {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (!(Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw '找不到 vswhere.exe，无法验证 Windows C++/ATL 环境。'
    }
    $installation = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 Microsoft.VisualStudio.Component.VC.ATL -property installationPath
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($installation | Select-Object -First 1))) {
        throw 'Visual Studio 缺少 ATL（atlstr.h）。请在生成工具中添加 C++ ATL 组件后重试。'
    }
}

$normalizedVersion = Normalize-ReleaseVersion $Version
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$appInfoPath = Join-Path $repoRoot 'lib\app\app_info.dart'
$versionInfo = Assert-VersionAgreement -Version $normalizedVersion -PubspecPath $pubspecPath -AppInfoPath $appInfoPath
$innoCompiler = $null
if ($Platform -in @('All', 'Windows')) {
    Assert-NuGetPresent
    Assert-VisualStudioAtlPresent
    $innoCompiler = Find-InnoCompiler
}
$versionRoot = Join-Path $outputRootFull "v$normalizedVersion"
Reset-VersionOutput -Path $versionRoot
$workRoot = Join-Path $versionRoot '.work'
New-Item -ItemType Directory -Path $workRoot | Out-Null

Push-Location $repoRoot
try {
    Invoke-Checked 'flutter pub get' { flutter pub get }
    if (!$SkipTests) {
        Invoke-Checked 'flutter analyze' { flutter analyze }
        Invoke-Checked 'flutter test' { flutter test }
    }

    $githubAssets = [System.Collections.Generic.List[object]]::new()
    $giteeAssets = [System.Collections.Generic.List[object]]::new()

    if ($Platform -in @('All', 'Android')) {
        $universalCode = Get-AndroidUniversalBuildNumber -PubspecBuildNumber $versionInfo.BuildNumber
        $splitBase = Get-AndroidSplitBaseBuildNumber -PubspecBuildNumber $versionInfo.BuildNumber
        $previousGradleHome = $env:GRADLE_USER_HOME
        $previousGradleOpts = $env:GRADLE_OPTS
        try {
            if ([string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME)) {
                $env:GRADLE_USER_HOME = Join-Path $env:USERPROFILE '.gradle\dream-manga-reader'
            }
            Remove-Item Env:GRADLE_OPTS -ErrorAction SilentlyContinue
            Invoke-Checked '构建 Android 通用 APK' {
                flutter build apk --release --build-name=$normalizedVersion --build-number=$universalCode
            }
            $apkOutput = Join-Path $repoRoot 'build\app\outputs\flutter-apk'
            $universalSource = Join-Path $apkOutput 'app-release.apk'
            $universalWork = Join-Path $workRoot 'DreamMangaReader-android-universal.apk'
            Copy-Item -LiteralPath $universalSource -Destination $universalWork -Force

            Invoke-Checked '构建 Android 分架构 APK' {
                flutter build apk --release --split-per-abi --build-name=$normalizedVersion --build-number=$splitBase
            }
        }
        finally {
            if ($null -eq $previousGradleHome) { Remove-Item Env:GRADLE_USER_HOME -ErrorAction SilentlyContinue } else { $env:GRADLE_USER_HOME = $previousGradleHome }
            if ($null -eq $previousGradleOpts) { Remove-Item Env:GRADLE_OPTS -ErrorAction SilentlyContinue } else { $env:GRADLE_OPTS = $previousGradleOpts }
        }

        $expectedCert = Get-KeystoreCertificateSha256
        $universalMetadata = Get-ApkMetadata -Path $universalWork
        if ($universalMetadata.PackageName -ne 'com.dreammoon.dream_manga_reader' -or
            $universalMetadata.VersionName -ne $normalizedVersion -or
            $universalMetadata.VersionCode -ne $universalCode -or
            $universalMetadata.CertificateSha256 -ne $expectedCert) {
            throw 'Android 通用 APK 的包名、版本号或签名不符合发布契约。'
        }
        $universalAsset = [pscustomobject]@{ Platform='android'; Arch='universal'; Kind='installer'; FileName='DreamMangaReader-android-universal.apk'; Path=$universalWork; IncludeInManifest=$true }
        $githubAssets.Add($universalAsset)
        $giteeAssets.Add($universalAsset)

        $splitMap = [ordered]@{
            'armeabi-v7a' = 'app-armeabi-v7a-release.apk'
            'arm64-v8a' = 'app-arm64-v8a-release.apk'
            'x86_64' = 'app-x86_64-release.apk'
        }
        foreach ($entry in $splitMap.GetEnumerator()) {
            $source = Join-Path $apkOutput $entry.Value
            if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少 Android 分架构 APK：$($entry.Value)" }
            $name = "DreamMangaReader-android-$($entry.Key).apk"
            $path = Join-Path $workRoot $name
            Copy-Item -LiteralPath $source -Destination $path -Force
            $metadata = Get-ApkMetadata -Path $path
            $expectedVersionCode = Get-AndroidSplitBuildNumber `
                -PubspecBuildNumber $versionInfo.BuildNumber `
                -Abi $entry.Key
            if ($metadata.PackageName -ne 'com.dreammoon.dream_manga_reader' -or
                $metadata.VersionName -ne $normalizedVersion -or
                $metadata.VersionCode -ne $expectedVersionCode -or
                $metadata.CertificateSha256 -ne $expectedCert) {
                throw "Android 分架构 APK 不满足升级或签名要求：$name"
            }
            $asset = [pscustomobject]@{ Platform='android'; Arch=$entry.Key; Kind='installer'; FileName=$name; Path=$path; IncludeInManifest=$true }
            $githubAssets.Add($asset)
            $giteeAssets.Add($asset)
            Write-Host "APK $name versionCode=$($metadata.VersionCode) cert=$($metadata.CertificateSha256)"
        }
    }

    if ($Platform -in @('All', 'Windows')) {
        $windowsBuildNumber = $versionInfo.BuildNumber
        $previousPath = $env:PATH
        try {
            $env:PATH = "$(Join-Path $repoRoot '.tools');$previousPath"
            Invoke-Checked '构建 Windows Release' {
                flutter build windows --release --build-name=$normalizedVersion --build-number=$windowsBuildNumber
            }
        }
        finally {
            $env:PATH = $previousPath
        }
        $windowsRelease = Join-Path $repoRoot 'build\windows\x64\runner\Release'
        if (!(Test-Path -LiteralPath (Join-Path $windowsRelease 'dream_manga_reader.exe') -PathType Leaf)) {
            throw "Windows 构建产物不完整：$windowsRelease"
        }
        foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
            $source = Join-Path $env:SystemRoot "System32\$dll"
            if (!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "系统缺少 VC++ 运行时：$dll" }
            Copy-Item -LiteralPath $source -Destination $windowsRelease -Force
        }

        $portableRoot = Join-Path $workRoot 'portable\DreamMangaReader'
        New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null
        Copy-Item -Path (Join-Path $windowsRelease '*') -Destination $portableRoot -Recurse -Force
        $zipPath = Join-Path $workRoot 'DreamMangaReader-windows-x64.zip'
        Compress-Archive -LiteralPath $portableRoot -DestinationPath $zipPath -CompressionLevel Optimal -Force

        $installerOutput = Join-Path $workRoot 'installer'
        New-Item -ItemType Directory -Path $installerOutput -Force | Out-Null
        $iss = Join-Path $repoRoot 'windows\installer\DreamMangaReader.iss'
        Invoke-Checked '构建 Inno Setup 安装器' {
            & $innoCompiler "/DMyAppVersion=$normalizedVersion" "/DSourceDir=$windowsRelease" "/DOutputDir=$installerOutput" $iss
        }
        $setupPath = Join-Path $installerOutput 'DreamMangaReader-windows-x64-setup.exe'
        if (!(Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw 'Inno Setup 未生成安装器。' }

        $setupAsset = [pscustomobject]@{ Platform='windows'; Arch='x64'; Kind='installer'; FileName='DreamMangaReader-windows-x64-setup.exe'; Path=$setupPath; IncludeInManifest=$true }
        $zipAsset = [pscustomobject]@{ Platform='windows'; Arch='x64'; Kind='portable'; FileName='DreamMangaReader-windows-x64.zip'; Path=$zipPath; IncludeInManifest=$false }
        $githubAssets.Add($setupAsset); $githubAssets.Add($zipAsset)
        $giteeAssets.Add($setupAsset); $giteeAssets.Add($zipAsset)
    }

    [void](New-ReleaseFolder -Destination (Join-Path $versionRoot 'github') -Assets $githubAssets.ToArray() -ReleaseVersion $normalizedVersion -ReleaseChannel $Channel -Gitee $false)
    [void](New-ReleaseFolder -Destination (Join-Path $versionRoot 'gitee') -Assets $giteeAssets.ToArray() -ReleaseVersion $normalizedVersion -ReleaseChannel $Channel -Gitee $true)

    Remove-Item -LiteralPath $workRoot -Recurse -Force
    Write-Host "发布包已生成：$versionRoot" -ForegroundColor Green
    Get-ChildItem -LiteralPath $versionRoot -File -Recurse | Where-Object { $_.FullName -notlike "$workRoot*" } | Select-Object FullName, Length
}
finally {
    Pop-Location
}
