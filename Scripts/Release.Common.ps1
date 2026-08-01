Set-StrictMode -Version Latest

$script:DreamMangaReaderAppId = 'DreamMangaReader'
$script:GiteeAttachmentLimitBytes = 100MB
$script:GiteePartSizeBytes = 48MB
$script:GiteeReleaseBudgetBytes = 850MB
$script:GiteeMaxReleaseCount = 3
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

function Get-ReleaseObjectValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -ieq $Name) { return $InputObject[$key] }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到待校验文件：$Path"
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-CombinedFileSha256 {
    param([Parameter(Mandatory)][string[]]$Paths)

    if ($Paths.Count -eq 0) { throw '组合 SHA-256 至少需要一个文件。' }
    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash(
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $buffer = [byte[]]::new(1MB)
    try {
        foreach ($path in $Paths) {
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "找不到待组合校验的文件：$path"
            }
            $stream = [System.IO.File]::OpenRead($path)
            try {
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $hash.AppendData($buffer, 0, $read)
                }
            }
            finally {
                $stream.Dispose()
            }
        }
        return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    }
    finally {
        $hash.Dispose()
    }
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
    return 5000 + $PubspecBuildNumber
}

function Get-AndroidSplitBaseBuildNumber {
    param([Parameter(Mandatory)][int]$PubspecBuildNumber)

    [void](Get-AndroidUniversalBuildNumber -PubspecBuildNumber $PubspecBuildNumber)
    return $PubspecBuildNumber
}

function Get-AndroidSplitBuildNumber {
    param(
        [Parameter(Mandatory)][int]$PubspecBuildNumber,
        [Parameter(Mandatory)][ValidateSet('armeabi-v7a', 'arm64-v8a', 'x86_64')][string]$Abi
    )

    $base = Get-AndroidSplitBaseBuildNumber -PubspecBuildNumber $PubspecBuildNumber
    $offset = switch ($Abi) {
        'armeabi-v7a' { 1000 }
        'arm64-v8a' { 2000 }
        'x86_64' { 4000 }
    }
    return $offset + $base
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

function Resolve-GiteeReleaseMetadata {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][ValidateSet('stable', 'beta')][string]$Channel,
        [AllowEmptyString()][string]$MetadataPath = ''
    )

    $normalizedVersion = Normalize-ReleaseVersion $Version
    $tag = "v$normalizedVersion"
    $name = "DreamMangaReader $tag"
    $body = $name
    $prerelease = $Channel -ne 'stable'
    $external = $false

    if (![string]::IsNullOrWhiteSpace($MetadataPath)) {
        $metadataPathFull = [System.IO.Path]::GetFullPath($MetadataPath)
        if (!(Test-Path -LiteralPath $metadataPathFull -PathType Leaf)) {
            throw "找不到 Release 元数据：$metadataPathFull"
        }
        try {
            $metadata = Get-Content -LiteralPath $metadataPathFull -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            throw "Release 元数据不是有效 JSON：$($_.Exception.Message)"
        }
        foreach ($property in @('tag_name', 'name', 'body', 'prerelease')) {
            if ($null -eq $metadata.PSObject.Properties[$property]) {
                throw "Release 元数据缺少字段：$property"
            }
        }
        if ([string]$metadata.tag_name -cne $tag) {
            throw "Release 元数据标签不一致：$($metadata.tag_name) / $tag"
        }
        if ([string]::IsNullOrWhiteSpace([string]$metadata.name)) {
            throw 'Release 元数据名称不能为空。'
        }
        if ($metadata.prerelease -isnot [bool]) {
            throw 'Release 元数据 prerelease 必须是布尔值。'
        }
        $name = [string]$metadata.name
        $body = [string]$metadata.body
        $prerelease = [bool]$metadata.prerelease
        $external = $true
    }

    return [pscustomobject]@{
        Tag = $tag
        Name = $name
        Body = $body
        Prerelease = $prerelease
        External = $external
    }
}

function Assert-GiteeReleaseContract {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocalFiles
    )

    $version = Normalize-ReleaseVersion ([string]$Manifest.version)
    $schemaValue = Get-ReleaseObjectValue -InputObject $Manifest -Name 'schemaVersion'
    $schemaVersion = if ($null -eq $schemaValue) { 1 } else { [int]$schemaValue }
    if ($schemaVersion -notin @(1, 2)) {
        throw "Gitee Release 清单 schemaVersion 无效：$schemaVersion"
    }
    $requiredAssets = @(
        'windows|x64|installer|DreamMangaReader-windows-x64-setup.exe',
        'android|universal|installer|DreamMangaReader-android-universal.apk',
        'android|armeabi-v7a|installer|DreamMangaReader-android-armeabi-v7a.apk',
        'android|arm64-v8a|installer|DreamMangaReader-android-arm64-v8a.apk',
        'android|x86_64|installer|DreamMangaReader-android-x86_64.apk'
    ) | Sort-Object
    $actualAssets = @($Manifest.assets | ForEach-Object {
        "$($_.platform)|$($_.arch)|$($_.kind)|$($_.fileName)"
    }) | Sort-Object
    $assetDifferences = @(Compare-Object -ReferenceObject $requiredAssets -DifferenceObject $actualAssets -CaseSensitive)
    if ($actualAssets.Count -ne $requiredAssets.Count -or $assetDifferences.Count -ne 0) {
        throw 'Gitee Release 必须同时包含 Windows x64 安装器、Android 通用 APK 和三个 ABI 分包。'
    }

    $hashFileName = "DreamMangaReader-v$version-sha256.txt"
    $requiredFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'dream-manga-reader-update.json',
        $hashFileName
    )) {
        $requiredFiles.Add($name)
    }
    foreach ($asset in @($Manifest.assets)) {
        $fileName = Assert-SafeFileName ([string]$asset.fileName)
        $parts = @()
        $partsValue = Get-ReleaseObjectValue -InputObject $asset -Name 'parts'
        if ($null -ne $partsValue) { $parts = @($partsValue) }
        if ($parts.Count -eq 0) {
            $requiredFiles.Add($fileName)
            continue
        }
        if ($schemaVersion -ne 2 -or $parts.Count -lt 2 -or $parts.Count -gt 64) {
            throw "Gitee Release 分片数量无效：$fileName"
        }
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $partName = Assert-SafeFileName ([string]$parts[$index].fileName)
            $expectedPartName = "$fileName.part$(($index + 1).ToString('000'))"
            if ($partName -cne $expectedPartName) {
                throw "Gitee Release 分片名称无效：$partName"
            }
            $requiredFiles.Add($partName)
        }
    }

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
        if (!(Test-GiteeAttachmentSize -Bytes $actualFile.Length)) {
            throw "Gitee Release 附件超过 100 MiB：$name"
        }
        $filesByName.Add($name, $actualFile)
    }

    $portableZipName = 'DreamMangaReader-windows-x64.zip'
    if ($filesByName.ContainsKey($portableZipName)) {
        $requiredFiles.Add($portableZipName)
    }

    $actualFileNames = @($filesByName.Keys) | Sort-Object
    $requiredFileNames = @($requiredFiles.ToArray()) | Sort-Object
    if (@($requiredFileNames | Select-Object -Unique).Count -ne $requiredFileNames.Count) {
        throw 'Gitee Release 清单映射到重复的物理附件。'
    }
    $fileDifferences = @(Compare-Object -ReferenceObject $requiredFileNames -DifferenceObject $actualFileNames -CaseSensitive)
    if ($actualFileNames.Count -ne $requiredFileNames.Count -or $fileDifferences.Count -ne 0) {
        throw 'Gitee Release 本地附件必须精确等于完整 All 构建集合。'
    }

    $expectedHashNames = @($requiredFileNames | Where-Object { $_ -cne $hashFileName }) | Sort-Object
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
        throw "Gitee SHA256 清单必须精确覆盖除自身外的其他 $($expectedHashNames.Count) 个附件。"
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

function Get-StaleRemoteAttachments {
    param(
        [Parameter(Mandatory)][object[]]$Local,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Remote
    )

    $localByName = @{}
    foreach ($item in $Local) {
        $name = if ($null -ne $item.PSObject.Properties['Name']) { [string]$item.Name } else { [string]$item.name }
        $length = if ($null -ne $item.PSObject.Properties['Length']) { [long]$item.Length } else { [long]$item.size }
        [void](Assert-SafeFileName $name)
        if (!(Test-GiteeAttachmentSize -Bytes $length)) {
            throw "Gitee 附件超过 100 MiB：$name"
        }
        $key = $name.ToLowerInvariant()
        if ($localByName.ContainsKey($key)) {
            throw "本地存在重复附件名：$name"
        }
        $localByName[$key] = $length
    }

    $remoteNames = @{}
    $stale = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Remote) {
        $name = [string]$item.name
        [void](Assert-SafeFileName $name)
        $key = $name.ToLowerInvariant()
        if ($remoteNames.ContainsKey($key)) {
            throw "远端存在重复附件名：$name"
        }
        $remoteNames[$key] = $true
        if (!$localByName.ContainsKey($key) -or [long]$item.size -ne $localByName[$key]) {
            $stale.Add($item)
        }
    }
    return $stale.ToArray()
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
        [Parameter(Mandatory)][object[]]$Assets,
        [ValidateSet(1, 2)][int]$SchemaVersion = 1
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
        $entry = [ordered]@{
            platform = $platform
            arch = $arch
            kind = $kind
            fileName = $fileName
            sha256 = Get-FileSha256 -Path $item.FullName
            sizeBytes = [long]$item.Length
        }
        $parts = @()
        $partsValue = Get-ReleaseObjectValue -InputObject $asset -Name 'Parts'
        if ($null -ne $partsValue) { $parts = @($partsValue) }
        if ($parts.Count -gt 0) {
            if ($SchemaVersion -ne 2 -or $parts.Count -lt 2 -or $parts.Count -gt 64) {
                throw "清单附件分片数量无效：$fileName"
            }
            $partEntries = [System.Collections.Generic.List[object]]::new()
            $partPaths = [System.Collections.Generic.List[string]]::new()
            $partSizeTotal = [long]0
            for ($index = 0; $index -lt $parts.Count; $index++) {
                $part = $parts[$index]
                $partName = Assert-SafeFileName ([string]$part.FileName)
                $expectedPartName = "$fileName.part$(($index + 1).ToString('000'))"
                if ($partName -cne $expectedPartName) {
                    throw "清单附件分片名称无效：$partName"
                }
                $partPath = [string]$part.Path
                if (!(Test-Path -LiteralPath $partPath -PathType Leaf)) {
                    throw "找不到清单附件分片：$partName"
                }
                $partItem = Get-Item -LiteralPath $partPath
                if ($partItem.Length -le 0 -or !(Test-GiteeAttachmentSize -Bytes $partItem.Length)) {
                    throw "清单附件分片大小无效：$partName"
                }
                $partSizeTotal += $partItem.Length
                $partPaths.Add($partItem.FullName)
                $partEntries.Add([ordered]@{
                    fileName = $partName
                    sha256 = Get-FileSha256 -Path $partItem.FullName
                    sizeBytes = [long]$partItem.Length
                })
            }
            if ($partSizeTotal -ne $item.Length -or
                (Get-CombinedFileSha256 -Paths $partPaths.ToArray()) -cne $entry.sha256) {
                throw "清单附件分片无法重组原文件：$fileName"
            }
            $entry['parts'] = @($partEntries.ToArray())
        }
        $entry
    }
    return [ordered]@{
        schemaVersion = $SchemaVersion
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
    $schemaVersion = [int]$Manifest.schemaVersion
    if ($schemaVersion -notin @(1, 2) -or
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
    $seenPhysicalNames = @{}
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
        $parts = @()
        $partsValue = Get-ReleaseObjectValue -InputObject $asset -Name 'parts'
        if ($null -ne $partsValue) { $parts = @($partsValue) }
        if ($parts.Count -eq 0) {
            if ($seenPhysicalNames.ContainsKey($key)) {
                throw "更新清单存在重复物理附件：$fileName"
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
            $seenPhysicalNames[$key] = $true
            continue
        }

        if ($schemaVersion -ne 2 -or $parts.Count -lt 2 -or $parts.Count -gt 64) {
            throw "附件分片数量无效：$fileName"
        }
        $partPaths = [System.Collections.Generic.List[string]]::new()
        $partSizeTotal = [long]0
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $part = $parts[$index]
            $partName = Assert-SafeFileName ([string]$part.fileName)
            $expectedPartName = "$fileName.part$(($index + 1).ToString('000'))"
            if ($partName -cne $expectedPartName) {
                throw "附件分片名称无效：$partName"
            }
            $partKey = $partName.ToLowerInvariant()
            if ($seenPhysicalNames.ContainsKey($partKey)) {
                throw "更新清单存在重复物理附件：$partName"
            }
            $seenPhysicalNames[$partKey] = $true
            if (!(Test-Sha256 ([string]$part.sha256))) {
                throw "附件分片 SHA-256 无效：$partName"
            }
            $partPath = Join-Path $AssetRoot $partName
            if (!(Test-Path -LiteralPath $partPath -PathType Leaf)) {
                throw "缺少附件分片：$partName"
            }
            $partItem = Get-Item -LiteralPath $partPath
            if ($partItem.Length -ne [long]$part.sizeBytes -or $partItem.Length -le 0) {
                throw "附件分片大小不一致：$partName"
            }
            if ((Get-FileSha256 -Path $partPath) -cne ([string]$part.sha256).ToLowerInvariant()) {
                throw "附件分片 SHA-256 不一致：$partName"
            }
            $partSizeTotal += $partItem.Length
            $partPaths.Add($partItem.FullName)
        }
        if ($partSizeTotal -ne [long]$asset.sizeBytes -or
            (Get-CombinedFileSha256 -Paths $partPaths.ToArray()) -cne ([string]$asset.sha256).ToLowerInvariant()) {
            throw "附件分片无法重组原文件：$fileName"
        }
    }
    return $true
}

function New-GiteeAssetParts {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$FileName,
        [long]$PartSizeBytes = $script:GiteePartSizeBytes
    )

    $safeFileName = Assert-SafeFileName $FileName
    if ($PartSizeBytes -le 0 -or !(Test-GiteeAttachmentSize -Bytes $PartSizeBytes)) {
        throw "Gitee 分片大小无效：$PartSizeBytes"
    }
    if (!(Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "找不到待分片附件：$SourcePath"
    }
    if (!(Test-Path -LiteralPath $Destination -PathType Container)) {
        throw "找不到分片输出目录：$Destination"
    }
    $sourceItem = Get-Item -LiteralPath $SourcePath
    if ($sourceItem.Length -le $PartSizeBytes) { return @() }
    $partCount = [int][Math]::Ceiling($sourceItem.Length / [double]$PartSizeBytes)
    if ($partCount -gt 64) {
        throw "Gitee 附件分片超过 64 个：$safeFileName / $partCount"
    }

    $parts = [System.Collections.Generic.List[object]]::new()
    $source = [System.IO.File]::OpenRead($sourceItem.FullName)
    $buffer = [byte[]]::new(1MB)
    try {
        for ($index = 1; $index -le $partCount; $index++) {
            $partName = "$safeFileName.part$($index.ToString('000'))"
            $partPath = Join-Path $Destination $partName
            $remaining = [Math]::Min($PartSizeBytes, $sourceItem.Length - $source.Position)
            $output = [System.IO.File]::Open($partPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
            try {
                while ($remaining -gt 0) {
                    $requested = [int][Math]::Min($buffer.Length, $remaining)
                    $read = $source.Read($buffer, 0, $requested)
                    if ($read -le 0) { throw "Gitee 附件分片读取提前结束：$safeFileName" }
                    $output.Write($buffer, 0, $read)
                    $remaining -= $read
                }
            }
            finally {
                $output.Dispose()
            }
            $parts.Add([pscustomobject]@{
                FileName = $partName
                Path = $partPath
            })
        }
    }
    finally {
        $source.Dispose()
    }
    return $parts.ToArray()
}

function New-ReleaseFolder {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][object[]]$Assets,
        [Parameter(Mandatory)][string]$ReleaseVersion,
        [Parameter(Mandatory)][ValidateSet('stable', 'beta')][string]$ReleaseChannel,
        [Parameter(Mandatory)][bool]$Gitee,
        [long]$GiteePartSizeBytes = $script:GiteePartSizeBytes
    )

    if (Test-Path -LiteralPath $Destination) {
        if (@(Get-ChildItem -LiteralPath $Destination -Force).Count -ne 0) {
            throw "发布目录必须为空：$Destination"
        }
    }
    else {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $manifestAssets = [System.Collections.Generic.List[object]]::new()
    foreach ($asset in $Assets) {
        $name = Assert-SafeFileName ([string]$asset.FileName)
        $sourcePath = [string]$asset.Path
        if (!(Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "找不到发布附件：$name"
        }
        $sourceItem = Get-Item -LiteralPath $sourcePath
        if ($sourceItem.Length -le 0) { throw "发布附件为空：$name" }
        $includeInManifest = [bool]$asset.IncludeInManifest

        if ($Gitee -and !$includeInManifest -and !(Test-GiteeAttachmentSize -Bytes $sourceItem.Length)) {
            Write-Warning "Gitee 跳过超过 100 MiB 的非更新附件：$name"
            continue
        }
        if ($Gitee -and $includeInManifest -and $sourceItem.Length -gt $GiteePartSizeBytes) {
            $parts = @(New-GiteeAssetParts -SourcePath $sourceItem.FullName -Destination $Destination -FileName $name -PartSizeBytes $GiteePartSizeBytes)
            $manifestAssets.Add([pscustomobject]@{
                Platform = $asset.Platform
                Arch = $asset.Arch
                Kind = $asset.Kind
                FileName = $name
                Path = $sourceItem.FullName
                Parts = $parts
            })
            continue
        }

        $destinationPath = Join-Path $Destination $name
        Copy-Item -LiteralPath $sourceItem.FullName -Destination $destinationPath
        if ($Gitee -and !(Test-GiteeAttachmentSize -Bytes (Get-Item -LiteralPath $destinationPath).Length)) {
            throw "Gitee 附件超过 100 MiB：$name"
        }
        if ($includeInManifest) {
            $manifestAssets.Add([pscustomobject]@{
                Platform = $asset.Platform
                Arch = $asset.Arch
                Kind = $asset.Kind
                FileName = $name
                Path = $destinationPath
                Parts = @()
            })
        }
    }

    $schemaVersion = if ($Gitee) { 2 } else { 1 }
    $manifest = New-UpdateManifest -Version $ReleaseVersion -Channel $ReleaseChannel -Assets $manifestAssets.ToArray() -SchemaVersion $schemaVersion
    $manifestPath = Join-Path $Destination 'dream-manga-reader-update.json'
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    [void](Test-ReleaseAssetSet -Manifest $manifest -AssetRoot $Destination)

    $hashName = "DreamMangaReader-v$ReleaseVersion-sha256.txt"
    $hashPath = Join-Path $Destination $hashName
    $hashLines = Get-ChildItem -LiteralPath $Destination -File |
        Where-Object { $_.Name -ne $hashName } |
        Sort-Object Name |
        ForEach-Object { "$(Get-FileSha256 -Path $_.FullName)  $($_.Name)" }
    $hashLines | Set-Content -LiteralPath $hashPath -Encoding ASCII

    if ($Gitee) {
        foreach ($file in Get-ChildItem -LiteralPath $Destination -File) {
            if (!(Test-GiteeAttachmentSize -Bytes $file.Length)) {
                throw "Gitee 附件超过 100 MiB：$($file.Name)"
            }
        }
    }
    return $manifest
}

function Get-GiteeReleaseRetentionPlan {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Releases,
        [Parameter(Mandatory)][string]$IncomingTag,
        [Parameter(Mandatory)][bool]$IncomingPrerelease,
        [Parameter(Mandatory)][long]$IncomingSizeBytes,
        [ValidateRange(1, 3)][int]$MaxReleaseCount = $script:GiteeMaxReleaseCount,
        [long]$BudgetBytes = $script:GiteeReleaseBudgetBytes
    )

    if ($IncomingSizeBytes -le 0 -or $BudgetBytes -le 0) {
        throw 'Gitee Release 容量参数必须为正数。'
    }
    $incomingVersionText = Normalize-ReleaseVersion $IncomingTag
    $incomingVersion = [System.Management.Automation.SemanticVersion]::Parse($incomingVersionText)
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($release in $Releases) {
        $tagProperty = $release.PSObject.Properties['Tag']
        if ($null -eq $tagProperty) { $tagProperty = $release.PSObject.Properties['tag_name'] }
        $sizeProperty = $release.PSObject.Properties['SizeBytes']
        if ($null -eq $tagProperty -or $null -eq $sizeProperty -or [long]$sizeProperty.Value -lt 0) {
            throw 'Gitee Release 保留计划缺少 Tag 或 SizeBytes。'
        }
        $tag = [string]$tagProperty.Value
        $prereleaseProperty = $release.PSObject.Properties['Prerelease']
        if ($null -eq $prereleaseProperty) { $prereleaseProperty = $release.PSObject.Properties['prerelease'] }
        try {
            $versionText = Normalize-ReleaseVersion $tag
            $version = [System.Management.Automation.SemanticVersion]::Parse($versionText)
            $managed = $true
        }
        catch {
            $version = $null
            $managed = $false
        }
        $records.Add([pscustomobject]@{
            Tag = $tag
            Version = $version
            Prerelease = $null -ne $prereleaseProperty -and $prereleaseProperty.Value -eq $true
            SizeBytes = [long]$sizeProperty.Value
            Managed = $managed
            Incoming = $false
            Release = $release
        })
    }

    $incoming = [pscustomobject]@{
        Tag = "v$incomingVersionText"
        Version = $incomingVersion
        Prerelease = $IncomingPrerelease
        SizeBytes = $IncomingSizeBytes
        Managed = $true
        Incoming = $true
        Release = $null
    }
    $protected = @($records | Where-Object { !$_.Managed })
    $managed = @($records | Where-Object { $_.Managed -and $_.Tag -cne $incoming.Tag }) + @($incoming)
    $ordered = @($managed | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true })

    $selected = [System.Collections.Generic.List[object]]::new()
    $selectedTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $selected.Add($incoming)
    [void]$selectedTags.Add($incoming.Tag)
    $latestStable = @($ordered | Where-Object { !$_.Prerelease } | Select-Object -First 1)
    if ($latestStable.Count -gt 0 -and $selectedTags.Add($latestStable[0].Tag)) {
        $selected.Add($latestStable[0])
    }
    foreach ($record in $ordered) {
        if ($selected.Count + $protected.Count -ge $MaxReleaseCount) { break }
        if ($selectedTags.Add($record.Tag)) { $selected.Add($record) }
    }

    $mandatoryTags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    [void]$mandatoryTags.Add($incoming.Tag)
    if ($latestStable.Count -gt 0) { [void]$mandatoryTags.Add($latestStable[0].Tag) }
    $projectedBytes = [long]0
    foreach ($record in @($protected) + @($selected)) {
        $projectedBytes += [long]$record.SizeBytes
    }
    while ($projectedBytes -gt $BudgetBytes) {
        $removable = @($selected | Where-Object { !$mandatoryTags.Contains($_.Tag) } |
            Sort-Object -Property @{ Expression = { $_.Version }; Descending = $false } |
            Select-Object -First 1)
        if ($removable.Count -eq 0) { break }
        [void]$selected.Remove($removable[0])
        [void]$selectedTags.Remove($removable[0].Tag)
        $projectedBytes -= [long]$removable[0].SizeBytes
    }

    $fitsCount = $selected.Count + $protected.Count -le $MaxReleaseCount
    $fitsBudget = $projectedBytes -le $BudgetBytes
    $retainedTags = @($protected | ForEach-Object { $_.Tag }) +
        @($selected | ForEach-Object { $_.Tag })
    $deleteReleases = @($records | Where-Object { $_.Managed -and $_.Tag -notin $retainedTags } | ForEach-Object { $_.Release })
    $reason = if (!$fitsCount) {
        '受保护 Release 与当前版本超过最大保留数量。'
    }
    elseif (!$fitsBudget) {
        '当前版本与必须保留的最新 stable 超过 Gitee Release 容量预算。'
    }
    else {
        ''
    }
    return [pscustomobject]@{
        Fits = $fitsCount -and $fitsBudget
        Reason = $reason
        ProjectedBytes = $projectedBytes
        BudgetBytes = $BudgetBytes
        RetainedTags = @($retainedTags)
        DeleteReleases = @($deleteReleases)
    }
}
