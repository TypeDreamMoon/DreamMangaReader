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

function Get-AndroidUniversalBuildNumber {
    param([Parameter(Mandatory)][int]$PubspecBuildNumber)

    if ($PubspecBuildNumber -le 0 -or $PubspecBuildNumber -ge 1000) {
        throw "pubspec build number 必须在 1..999：$PubspecBuildNumber"
    }
    return 10000 + $PubspecBuildNumber
}

function Get-AndroidSplitBaseBuildNumber {
    param([Parameter(Mandatory)][int]$PubspecBuildNumber)

    return Get-AndroidUniversalBuildNumber -PubspecBuildNumber $PubspecBuildNumber
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

function Assert-GiteeTarget {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repository
    )

    if ($Owner -cne 'TypeDreamMoon' -or $Repository -cne 'DreamMangaReader') {
        throw "拒绝发布到未授权仓库：$Owner/$Repository"
    }
    return $true
}

function Assert-GiteeReleaseContract {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocalFiles
    )

    $version = Normalize-ReleaseVersion ([string]$Manifest.version)
    $requiredAssets = @(
        'windows|x64|installer|DreamMangaReader-windows-x64-setup.exe',
        'android|armeabi-v7a|installer|DreamMangaReader-android-armeabi-v7a.apk',
        'android|arm64-v8a|installer|DreamMangaReader-android-arm64-v8a.apk',
        'android|x86_64|installer|DreamMangaReader-android-x86_64.apk'
    ) | Sort-Object
    $actualAssets = @($Manifest.assets | ForEach-Object {
        "$($_.platform)|$($_.arch)|$($_.kind)|$($_.fileName)"
    }) | Sort-Object
    $assetDifferences = @(Compare-Object -ReferenceObject $requiredAssets -DifferenceObject $actualAssets -CaseSensitive)
    if ($actualAssets.Count -ne $requiredAssets.Count -or $assetDifferences.Count -ne 0) {
        throw 'Gitee Release 必须同时包含 Windows x64 安装器和三个 Android ABI 分包，且不得使用通用 APK 代替。'
    }

    $hashFileName = "DreamMangaReader-v$version-sha256.txt"
    $requiredFiles = @(
        'dream-manga-reader-update.json',
        $hashFileName,
        'DreamMangaReader-windows-x64-setup.exe',
        'DreamMangaReader-windows-x64.zip',
        'DreamMangaReader-android-armeabi-v7a.apk',
        'DreamMangaReader-android-arm64-v8a.apk',
        'DreamMangaReader-android-x86_64.apk'
    )

    $filesByName = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($file in $LocalFiles) {
        if ($null -eq $file -or
            $null -eq $file.PSObject.Properties['Name'] -or
            $null -eq $file.PSObject.Properties['Length'] -or
            $null -eq $file.PSObject.Properties['FullName']) {
            throw 'Gitee Release 附件必须提供 Name、Length 和 FullName。'
        }
        $name = Assert-SafeFileName ([string]$file.Name)
        $fullName = [string]$file.FullName
        if ([System.IO.Path]::GetFileName($fullName) -cne $name -or
            !(Test-Path -LiteralPath $fullName -PathType Leaf)) {
            throw "Gitee Release 附件路径无效：$name"
        }
        if ($filesByName.ContainsKey($name)) {
            throw "Gitee Release 存在重复附件：$name"
        }
        $actualFile = Get-Item -LiteralPath $fullName
        if ([long]$file.Length -ne $actualFile.Length) {
            throw "Gitee Release 附件信息已失效：$name"
        }
        if ($actualFile.Length -le 0) {
            throw "Gitee Release 附件为空：$name"
        }
        $filesByName.Add($name, $actualFile)
    }

    $actualFileNames = @($filesByName.Keys) | Sort-Object
    $requiredFileNames = @($requiredFiles) | Sort-Object
    $fileDifferences = @(Compare-Object -ReferenceObject $requiredFileNames -DifferenceObject $actualFileNames -CaseSensitive)
    if ($actualFileNames.Count -ne $requiredFileNames.Count -or $fileDifferences.Count -ne 0) {
        throw 'Gitee Release 本地附件必须精确等于完整 All 构建集合。'
    }

    $expectedHashNames = @($requiredFiles | Where-Object { $_ -cne $hashFileName }) | Sort-Object
    $hashesByName = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $hashPath = $filesByName[$hashFileName].FullName
    foreach ($line in @(Get-Content -LiteralPath $hashPath -Encoding ASCII)) {
        if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
            throw "Gitee SHA256 清单格式无效：$line"
        }
        $hash = $Matches[1].ToLowerInvariant()
        $name = Assert-SafeFileName $Matches[2]
        if ($hashesByName.ContainsKey($name)) {
            throw "Gitee SHA256 清单存在重复条目：$name"
        }
        $hashesByName.Add($name, $hash)
    }

    $actualHashNames = @($hashesByName.Keys) | Sort-Object
    $hashDifferences = @(Compare-Object -ReferenceObject $expectedHashNames -DifferenceObject $actualHashNames -CaseSensitive)
    if ($actualHashNames.Count -ne $expectedHashNames.Count -or $hashDifferences.Count -ne 0) {
        throw 'Gitee SHA256 清单必须精确覆盖除自身外的其他 6 个附件。'
    }
    foreach ($name in $expectedHashNames) {
        $actualHash = Get-FileSha256 -Path $filesByName[$name].FullName
        if ($hashesByName[$name] -cne $actualHash) {
            throw "Gitee SHA256 校验失败：$name"
        }
    }
    return $true
}

function Compare-RemoteAttachments {
    param(
        [Parameter(Mandatory)][object[]]$Local,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Remote,
        [scriptblock]$GetRemoteSha256
    )

    $remoteByName = @{}
    foreach ($item in $Remote) {
        $name = [string]$item.name
        [void](Assert-SafeFileName $name)
        $key = $name.ToLowerInvariant()
        if ($remoteByName.ContainsKey($key)) {
            throw "远端存在重复附件名：$name"
        }
        $remoteByName[$key] = $item
    }

    $missing = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Local) {
        $name = if ($null -ne $item.PSObject.Properties['Name']) { [string]$item.Name } else { [string]$item.name }
        $length = if ($null -ne $item.PSObject.Properties['Length']) { [long]$item.Length } else { [long]$item.size }
        [void](Assert-SafeFileName $name)
        if (!(Test-GiteeAttachmentSize -Bytes $length)) {
            throw "Gitee 附件超过 100 MiB：$name"
        }
        $key = $name.ToLowerInvariant()
        if (!$remoteByName.ContainsKey($key)) {
            $missing.Add($item)
            continue
        }
        $remoteLength = [long]$remoteByName[$key].size
        if ($remoteLength -ne $length) {
            throw "远端同名附件大小冲突：$name（本地 $length，远端 $remoteLength）"
        }
        if ($null -ne $GetRemoteSha256) {
            if ($null -eq $item.PSObject.Properties['FullName']) {
                throw "本地附件缺少完整路径，无法执行远端 SHA-256 校验：$name"
            }
            $remoteHash = [string](& $GetRemoteSha256 $remoteByName[$key])
            if (!(Test-Sha256 $remoteHash)) {
                throw "远端附件 SHA-256 无效：$name"
            }
            $localHash = Get-FileSha256 -Path ([string]$item.FullName)
            if ($remoteHash.ToLowerInvariant() -cne $localHash) {
                throw "远端同名附件 SHA-256 冲突：$name"
            }
        }
    }
    return $missing.ToArray()
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
    if ($pubspec.Version -ne $expected -or $appInfoVersion -ne $expected) {
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
