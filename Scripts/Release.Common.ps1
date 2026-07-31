Set-StrictMode -Version Latest

$script:DreamMangaReaderAppId = 'DreamMangaReader'
$script:GiteeAttachmentLimitBytes = 100MB
$script:ReleaseVersionPattern = '^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'

function Normalize-ReleaseVersion {
    param([Parameter(Mandatory)][string]$Version)

    $normalized = $Version.Trim() -replace '^v', ''
    if ($normalized -notmatch $script:ReleaseVersionPattern) {
        throw "发布版本格式无效：$Version"
    }
    return $normalized
}

function Test-Sha256 {
    param([AllowNull()][string]$Value)

    return ![string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[0-9a-fA-F]{64}$'
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到待校验文件：$Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-GiteeAttachmentSize {
    param([Parameter(Mandatory)][long]$Bytes)

    return $Bytes -ge 0 -and $Bytes -le $script:GiteeAttachmentLimitBytes
}

function Assert-SafeFileName {
    param([Parameter(Mandatory)][string]$FileName)

    if ([string]::IsNullOrWhiteSpace($FileName) -or
        $FileName -ne [System.IO.Path]::GetFileName($FileName) -or
        $FileName.Contains('/') -or
        $FileName.Contains('\') -or
        $FileName.Contains('..') -or
        $FileName.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "不安全的附件文件名：$FileName"
    }
    return $FileName
}

function Read-ReleaseVersion {
    param([Parameter(Mandatory)][string]$PubspecPath)

    if (!(Test-Path -LiteralPath $PubspecPath -PathType Leaf)) {
        throw "找不到 pubspec.yaml：$PubspecPath"
    }
    $content = Get-Content -LiteralPath $PubspecPath -Raw -Encoding UTF8
    if ($content -notmatch '(?m)^version:\s*([^\s+#]+)\+(\d+)\s*$') {
        throw "pubspec.yaml 缺少有效的 version: x.y.z+n：$PubspecPath"
    }
    $version = Normalize-ReleaseVersion $Matches[1]
    return [pscustomobject]@{
        Version = $version
        BuildNumber = [int]$Matches[2]
        Raw = "$version+$($Matches[2])"
    }
}

function Assert-VersionAgreement {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$PubspecPath,
        [Parameter(Mandatory)][string]$AppInfoPath
    )

    $expected = Normalize-ReleaseVersion $Version
    $pubspec = Read-ReleaseVersion -PubspecPath $PubspecPath
    if (!(Test-Path -LiteralPath $AppInfoPath -PathType Leaf)) {
        throw "找不到 AppInfo：$AppInfoPath"
    }
    $appInfoContent = Get-Content -LiteralPath $AppInfoPath -Raw -Encoding UTF8
    if ($appInfoContent -notmatch "static\s+const\s+version\s*=\s*'([^']+)'\s*;") {
        throw "AppInfo 缺少静态 version：$AppInfoPath"
    }
    $appInfoVersion = Normalize-ReleaseVersion $Matches[1]
    $expectedBase = ($expected -split '-', 2)[0]
    if ($pubspec.Version -ne $expectedBase -or $appInfoVersion -ne $expected) {
        throw "版本不一致：请求=$expected pubspec=$($pubspec.Version) AppInfo=$appInfoVersion"
    }
    return $pubspec
}

function New-UpdateManifest {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][ValidateSet('stable', 'beta')][string]$Channel,
        [Parameter(Mandatory)][object[]]$Assets
    )

    $normalizedVersion = Normalize-ReleaseVersion $Version
    if ($Assets.Count -eq 0) {
        throw '更新清单至少需要一个附件。'
    }
    $manifestAssets = foreach ($asset in $Assets) {
        $fileName = Assert-SafeFileName ([string]$asset.FileName)
        $platform = [string]$asset.Platform
        $arch = [string]$asset.Arch
        $kind = [string]$asset.Kind
        if ($platform -notin @('windows', 'android')) {
            throw "清单附件平台无效：$fileName / $platform"
        }
        if ([string]::IsNullOrWhiteSpace($arch) -or [string]::IsNullOrWhiteSpace($kind)) {
            throw "清单附件缺少 arch 或 kind：$fileName"
        }
        $path = [string]$asset.Path
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "找不到清单附件：$fileName"
        }
        $item = Get-Item -LiteralPath $path
        if ($item.Length -le 0) {
            throw "清单附件为空：$fileName"
        }
        [ordered]@{
            platform = $platform
            arch = $arch
            kind = $kind
            fileName = $fileName
            sha256 = Get-FileSha256 -Path $item.FullName
            sizeBytes = [long]$item.Length
        }
    }
    return [ordered]@{
        schemaVersion = 1
        appId = $script:DreamMangaReaderAppId
        version = $normalizedVersion
        channel = $Channel
        assets = @($manifestAssets)
    }
}

function Test-ReleaseAssetSet {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$AssetRoot
    )

    if (!(Test-Path -LiteralPath $AssetRoot -PathType Container)) {
        throw "找不到附件目录：$AssetRoot"
    }
    if ([int]$Manifest.schemaVersion -ne 1 -or
        [string]$Manifest.appId -ne $script:DreamMangaReaderAppId) {
        throw '更新清单标识或 schemaVersion 无效。'
    }
    [void](Normalize-ReleaseVersion ([string]$Manifest.version))
    if ([string]$Manifest.channel -notin @('stable', 'beta')) {
        throw "更新清单 channel 无效：$($Manifest.channel)"
    }
    $assets = @($Manifest.assets)
    if ($assets.Count -eq 0) {
        throw '更新清单没有附件。'
    }
    $seenNames = @{}
    foreach ($asset in $assets) {
        $fileName = Assert-SafeFileName ([string]$asset.fileName)
        $key = $fileName.ToLowerInvariant()
        if ($seenNames.ContainsKey($key)) {
            throw "更新清单存在重复附件：$fileName"
        }
        $seenNames[$key] = $true
        if (!(Test-Sha256 ([string]$asset.sha256))) {
            throw "附件 SHA-256 无效：$fileName"
        }
        $path = Join-Path $AssetRoot $fileName
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "缺少附件：$fileName"
        }
        $item = Get-Item -LiteralPath $path
        if ($item.Length -ne [long]$asset.sizeBytes) {
            throw "附件大小不一致：$fileName"
        }
        if ((Get-FileSha256 -Path $path) -ne ([string]$asset.sha256).ToLowerInvariant()) {
            throw "附件 SHA-256 不一致：$fileName"
        }
    }
    return $true
}
