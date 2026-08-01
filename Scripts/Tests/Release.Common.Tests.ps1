$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\Release.Common.ps1"

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message Expected=$Expected Actual=$Actual"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)

    try {
        & $Action
    }
    catch {
        return
    }
    throw "$Message Expected an exception."
}

Assert-Equal '1.3.1' (Normalize-ReleaseVersion 'v1.3.1') 'version'
Assert-Equal '1.3.1-beta.2' (Normalize-ReleaseVersion '1.3.1-beta.2') 'beta version'
Assert-Equal $true (Test-Sha256 ('a' * 64)) 'valid SHA'
Assert-Equal $false (Test-Sha256 '../bad') 'invalid SHA'
Assert-Equal $true (Test-GiteeAttachmentSize -Bytes 99MB) 'under limit'
Assert-Equal $true (Test-GiteeAttachmentSize -Bytes 100MB) 'at limit'
Assert-Equal $false (Test-GiteeAttachmentSize -Bytes 101MB) 'over limit'
Assert-Equal 'package.apk' (Assert-SafeFileName 'package.apk') 'safe file name'
Assert-Throws { Assert-SafeFileName '..\package.apk' } 'path traversal'
Assert-Equal 5013 (Get-AndroidUniversalBuildNumber -PubspecBuildNumber 13) 'universal code'
Assert-Equal 13 (Get-AndroidSplitBaseBuildNumber -PubspecBuildNumber 13) 'split base'
Assert-Equal 1013 (Get-AndroidSplitBuildNumber -PubspecBuildNumber 13 -Abi armeabi-v7a) 'armeabi-v7a code'
Assert-Equal 2013 (Get-AndroidSplitBuildNumber -PubspecBuildNumber 13 -Abi arm64-v8a) 'arm64-v8a code'
Assert-Equal 4013 (Get-AndroidSplitBuildNumber -PubspecBuildNumber 13 -Abi x86_64) 'x86_64 code'
Assert-Throws { Get-AndroidUniversalBuildNumber -PubspecBuildNumber 0 } 'invalid Android build number'
Assert-Equal $true (Assert-GiteeTarget -Owner TypeDreamMoon -Repository DreamMangaReader) 'Gitee target'
Assert-Throws { Assert-GiteeTarget -Owner someone -Repository DreamMangaReader } 'wrong Gitee owner'

function Write-GiteeHashFile {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$FileNames)

    $hashPath = Join-Path $Root 'DreamMangaReader-v1.3.1-sha256.txt'
    $lines = $FileNames | Sort-Object | ForEach-Object {
        "$(Get-FileSha256 -Path (Join-Path $Root $_))  $_"
    }
    $lines | Set-Content -LiteralPath $hashPath -Encoding ASCII
}

$fullGiteeManifest = [pscustomobject]@{
    schemaVersion = 2
    version = '1.3.1'
    assets = @(
        [pscustomobject]@{ platform='windows'; arch='x64'; kind='installer'; fileName='DreamMangaReader-windows-x64-setup.exe' },
        [pscustomobject]@{ platform='android'; arch='universal'; kind='installer'; fileName='DreamMangaReader-android-universal.apk' },
        [pscustomobject]@{ platform='android'; arch='armeabi-v7a'; kind='installer'; fileName='DreamMangaReader-android-armeabi-v7a.apk' },
        [pscustomobject]@{ platform='android'; arch='arm64-v8a'; kind='installer'; fileName='DreamMangaReader-android-arm64-v8a.apk' },
        [pscustomobject]@{ platform='android'; arch='x86_64'; kind='installer'; fileName='DreamMangaReader-android-x86_64.apk' }
    )
}
$fullGiteeNames = @(
    'dream-manga-reader-update.json',
    'DreamMangaReader-v1.3.1-sha256.txt',
    'DreamMangaReader-windows-x64-setup.exe',
    'DreamMangaReader-windows-x64.zip',
    'DreamMangaReader-android-universal.apk',
    'DreamMangaReader-android-armeabi-v7a.apk',
    'DreamMangaReader-android-arm64-v8a.apk',
    'DreamMangaReader-android-x86_64.apk'
)
$hashedGiteeNames = @($fullGiteeNames | Where-Object { $_ -cne 'DreamMangaReader-v1.3.1-sha256.txt' })
$giteeTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DreamMangaReader-gitee-contract-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $giteeTempRoot | Out-Null
try {
    foreach ($name in $hashedGiteeNames) {
        [System.IO.File]::WriteAllText((Join-Path $giteeTempRoot $name), "fixture:$name", [System.Text.UTF8Encoding]::new($false))
    }
    Write-GiteeHashFile -Root $giteeTempRoot -FileNames $hashedGiteeNames

    $fullGiteeFiles = @(Get-ChildItem -LiteralPath $giteeTempRoot -File)
    Assert-Equal $true (Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles $fullGiteeFiles) 'full Gitee release contract'

    $requiredGiteeNames = @($fullGiteeNames | Where-Object { $_ -cne 'DreamMangaReader-windows-x64.zip' })
    foreach ($missingName in $requiredGiteeNames) {
        Assert-Throws {
            Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles @($fullGiteeFiles | Where-Object { $_.Name -cne $missingName })
        } "Gitee release missing $missingName"
    }
    Write-GiteeHashFile -Root $giteeTempRoot -FileNames @($hashedGiteeNames | Where-Object { $_ -cne 'DreamMangaReader-windows-x64.zip' })
    Assert-Equal $true (Assert-GiteeReleaseContract `
        -Manifest $fullGiteeManifest `
        -LocalFiles @(Get-ChildItem -LiteralPath $giteeTempRoot -File | Where-Object { $_.Name -cne 'DreamMangaReader-windows-x64.zip' })) 'Gitee release without optional portable ZIP'
    Write-GiteeHashFile -Root $giteeTempRoot -FileNames $hashedGiteeNames

    $manifestWithoutUniversal = [pscustomobject]@{
        schemaVersion = 2
        version = '1.3.1'
        assets = @($fullGiteeManifest.assets | Where-Object { $_.arch -cne 'universal' })
    }
    Assert-Throws {
        Assert-GiteeReleaseContract -Manifest $manifestWithoutUniversal -LocalFiles $fullGiteeFiles
    } 'Gitee manifest without universal APK'

    $extraPath = Join-Path $giteeTempRoot 'unexpected.txt'
    [System.IO.File]::WriteAllText($extraPath, 'unexpected', [System.Text.UTF8Encoding]::new($false))
    Assert-Throws {
        Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles @(Get-ChildItem -LiteralPath $giteeTempRoot -File)
    } 'Gitee release with unexpected attachment'
    Remove-Item -LiteralPath $extraPath -Force

    foreach ($emptyName in $fullGiteeNames) {
        $emptyPath = Join-Path $giteeTempRoot $emptyName
        $originalBytes = [System.IO.File]::ReadAllBytes($emptyPath)
        try {
            [System.IO.File]::WriteAllBytes($emptyPath, [byte[]]::new(0))
            Assert-Throws {
                Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles @(Get-ChildItem -LiteralPath $giteeTempRoot -File)
            } "Gitee release with empty $emptyName"
        }
        finally {
            [System.IO.File]::WriteAllBytes($emptyPath, $originalBytes)
        }
    }

    $hashPath = Join-Path $giteeTempRoot 'DreamMangaReader-v1.3.1-sha256.txt'
    Write-GiteeHashFile -Root $giteeTempRoot -FileNames @($hashedGiteeNames | Select-Object -Skip 1)
    Assert-Throws {
        Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles @(Get-ChildItem -LiteralPath $giteeTempRoot -File)
    } 'Gitee SHA256 file missing entry'

    Write-GiteeHashFile -Root $giteeTempRoot -FileNames $hashedGiteeNames
    $duplicateLine = Get-Content -LiteralPath $hashPath -Encoding ASCII | Select-Object -First 1
    Add-Content -LiteralPath $hashPath -Value $duplicateLine -Encoding ASCII
    Assert-Throws {
        Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles @(Get-ChildItem -LiteralPath $giteeTempRoot -File)
    } 'Gitee SHA256 file with duplicate entry'

    Write-GiteeHashFile -Root $giteeTempRoot -FileNames $hashedGiteeNames
    Add-Content -LiteralPath $hashPath -Value "$('f' * 64)  unexpected.txt" -Encoding ASCII
    Assert-Throws {
        Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles @(Get-ChildItem -LiteralPath $giteeTempRoot -File)
    } 'Gitee SHA256 file with extra entry'

    Write-GiteeHashFile -Root $giteeTempRoot -FileNames $hashedGiteeNames
    $hashLines = @(Get-Content -LiteralPath $hashPath -Encoding ASCII)
    $hashLines[0] = "$('0' * 64)  $($hashLines[0].Substring(66))"
    $hashLines | Set-Content -LiteralPath $hashPath -Encoding ASCII
    Assert-Throws {
        Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles @(Get-ChildItem -LiteralPath $giteeTempRoot -File)
    } 'Gitee SHA256 file with wrong hash'
}
finally {
    Remove-Item -LiteralPath $giteeTempRoot -Recurse -Force
}

$localAttachments = @(
    [pscustomobject]@{ Name = 'a.apk'; Length = 12 },
    [pscustomobject]@{ Name = 'b.exe'; Length = 34 }
)
$missingAttachments = @(Compare-RemoteAttachments -Local $localAttachments -Remote @(
    [pscustomobject]@{ name = 'a.apk'; size = 12 }
))
Assert-Equal 1 $missingAttachments.Count 'one missing attachment'
Assert-Equal 'b.exe' $missingAttachments[0].Name 'missing attachment name'
Assert-Equal 0 @(Compare-RemoteAttachments -Local $localAttachments -Remote @(
    [pscustomobject]@{ name = 'a.apk'; size = 12 },
    [pscustomobject]@{ name = 'b.exe'; size = 34 }
)).Count 'complete attachments'
Assert-Throws {
    Compare-RemoteAttachments -Local $localAttachments -Remote @(
        [pscustomobject]@{ name = 'a.apk'; size = 99 }
    )
} 'same-name size conflict'

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DreamMangaReader-release-tests-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $pubspecFixture = Join-Path $tempRoot 'pubspec.yaml'
    $appInfoFixture = Join-Path $tempRoot 'app_info.dart'
    "name: fixture`nversion: 1.3.1+13`n" | Set-Content -LiteralPath $pubspecFixture -Encoding UTF8
    "class AppInfo { static const version = '1.3.1'; }`n" | Set-Content -LiteralPath $appInfoFixture -Encoding UTF8
    $releaseVersion = Assert-VersionAgreement -Version 'v1.3.1' -PubspecPath $pubspecFixture -AppInfoPath $appInfoFixture
    Assert-Equal 13 $releaseVersion.BuildNumber 'version agreement build number'
    "class AppInfo { static const version = '1.3.0'; }`n" | Set-Content -LiteralPath $appInfoFixture -Encoding UTF8
    Assert-Throws {
        Assert-VersionAgreement -Version '1.3.1' -PubspecPath $pubspecFixture -AppInfoPath $appInfoFixture
    } 'version disagreement'

    "name: fixture`nversion: 1.3.2-beta.1+14`n" | Set-Content -LiteralPath $pubspecFixture -Encoding UTF8
    "class AppInfo { static const version = '1.3.2-beta.1'; }`n" | Set-Content -LiteralPath $appInfoFixture -Encoding UTF8
    $betaVersion = Assert-VersionAgreement -Version 'v1.3.2-beta.1' -PubspecPath $pubspecFixture -AppInfoPath $appInfoFixture
    Assert-Equal '1.3.2-beta.1' $betaVersion.Version 'beta version agreement'
    Assert-Equal 14 $betaVersion.BuildNumber 'beta build number'

    $defaultMetadata = Resolve-GiteeReleaseMetadata -Version '1.3.2' -Channel stable
    Assert-Equal 'v1.3.2' $defaultMetadata.Tag 'default release metadata tag'
    Assert-Equal 'DreamMangaReader v1.3.2' $defaultMetadata.Name 'default release metadata name'
    Assert-Equal $false $defaultMetadata.Prerelease 'default release metadata prerelease'
    Assert-Equal $false $defaultMetadata.External 'default release metadata source'

    $metadataPath = Join-Path $tempRoot 'github-release.json'
    [System.IO.File]::WriteAllText($metadataPath, (@{
        tag_name = 'v1.3.2-beta.1'
        name = 'DreamMangaReader beta'
        body = "First line`nSecond line"
        prerelease = $true
    } | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    $githubMetadata = Resolve-GiteeReleaseMetadata -Version '1.3.2-beta.1' -Channel beta -MetadataPath $metadataPath
    Assert-Equal 'DreamMangaReader beta' $githubMetadata.Name 'GitHub release metadata name'
    Assert-Equal "First line`nSecond line" $githubMetadata.Body 'GitHub release metadata body'
    Assert-Equal $true $githubMetadata.Prerelease 'GitHub release metadata prerelease'
    Assert-Equal $true $githubMetadata.External 'GitHub release metadata source'
    Assert-Throws {
        Resolve-GiteeReleaseMetadata -Version '1.3.2' -Channel stable -MetadataPath $metadataPath
    } 'release metadata tag mismatch'

    $assetPath = Join-Path $tempRoot 'package.apk'
    [System.IO.File]::WriteAllBytes($assetPath, [byte[]](1, 2, 3))
    Assert-Equal '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81' (Get-FileSha256 $assetPath) 'file SHA'

    $localHashAttachments = @(Get-Item -LiteralPath $assetPath)
    $matchingRemote = @([pscustomobject]@{
        name = 'package.apk'
        size = 3
        sha256 = Get-FileSha256 $assetPath
    })
    Assert-Equal 0 @(Compare-RemoteAttachments -Local $localHashAttachments -Remote $matchingRemote -GetRemoteSha256 {
        param($remote)
        return $remote.sha256
    }).Count 'matching remote SHA'
    $matchingRemote[0].sha256 = 'f' * 64
    Assert-Throws {
        Compare-RemoteAttachments -Local $localHashAttachments -Remote $matchingRemote -GetRemoteSha256 {
            param($remote)
            return $remote.sha256
        }
    } 'same-size remote SHA conflict'

    $asset = [pscustomobject]@{
        Platform = 'android'
        Arch = 'arm64-v8a'
        Kind = 'installer'
        FileName = 'package.apk'
        Path = $assetPath
    }
    $manifest = New-UpdateManifest -Version '1.3.1' -Channel stable -Assets @($asset)
    Assert-Equal 'DreamMangaReader' $manifest.appId 'manifest app id'
    Assert-Equal 3 $manifest.assets[0].sizeBytes 'manifest size'
    Assert-Equal $true (Test-Sha256 $manifest.assets[0].sha256) 'manifest SHA'
    if (($manifest | ConvertTo-Json -Depth 8) -match [regex]::Escape($tempRoot)) {
        throw 'Manifest leaked an absolute local path.'
    }
    $invalidAsset = $asset.PSObject.Copy()
    $invalidAsset.Platform = 'linux'
    Assert-Throws {
        New-UpdateManifest -Version '1.3.1' -Channel stable -Assets @($invalidAsset)
    } 'invalid platform'

    Assert-Equal $true (Test-ReleaseAssetSet -Manifest $manifest -AssetRoot $tempRoot) 'complete assets'
    Assert-Throws {
        Test-ReleaseAssetSet -Manifest $manifest -AssetRoot (Join-Path $tempRoot 'missing')
    } 'missing asset root'

    $bundleSource = Join-Path $tempRoot 'bundle-source'
    $bundleDestination = Join-Path $tempRoot 'bundle-gitee'
    New-Item -ItemType Directory -Path $bundleSource | Out-Null
    $bundleFixtures = [ordered]@{
        'DreamMangaReader-windows-x64-setup.exe' = [byte[]](1, 2, 3, 4, 5)
        'DreamMangaReader-windows-x64.zip' = [byte[]](6)
        'DreamMangaReader-android-universal.apk' = [byte[]](10, 11, 12, 13, 14)
        'DreamMangaReader-android-armeabi-v7a.apk' = [byte[]](7)
        'DreamMangaReader-android-arm64-v8a.apk' = [byte[]](8)
        'DreamMangaReader-android-x86_64.apk' = [byte[]](9)
    }
    foreach ($fixture in $bundleFixtures.GetEnumerator()) {
        [System.IO.File]::WriteAllBytes((Join-Path $bundleSource $fixture.Key), $fixture.Value)
    }
    $bundleAssets = @(
        [pscustomobject]@{ Platform='windows'; Arch='x64'; Kind='installer'; FileName='DreamMangaReader-windows-x64-setup.exe'; Path=(Join-Path $bundleSource 'DreamMangaReader-windows-x64-setup.exe'); IncludeInManifest=$true },
        [pscustomobject]@{ Platform='windows'; Arch='x64'; Kind='portable'; FileName='DreamMangaReader-windows-x64.zip'; Path=(Join-Path $bundleSource 'DreamMangaReader-windows-x64.zip'); IncludeInManifest=$false },
        [pscustomobject]@{ Platform='android'; Arch='universal'; Kind='installer'; FileName='DreamMangaReader-android-universal.apk'; Path=(Join-Path $bundleSource 'DreamMangaReader-android-universal.apk'); IncludeInManifest=$true },
        [pscustomobject]@{ Platform='android'; Arch='armeabi-v7a'; Kind='installer'; FileName='DreamMangaReader-android-armeabi-v7a.apk'; Path=(Join-Path $bundleSource 'DreamMangaReader-android-armeabi-v7a.apk'); IncludeInManifest=$true },
        [pscustomobject]@{ Platform='android'; Arch='arm64-v8a'; Kind='installer'; FileName='DreamMangaReader-android-arm64-v8a.apk'; Path=(Join-Path $bundleSource 'DreamMangaReader-android-arm64-v8a.apk'); IncludeInManifest=$true },
        [pscustomobject]@{ Platform='android'; Arch='x86_64'; Kind='installer'; FileName='DreamMangaReader-android-x86_64.apk'; Path=(Join-Path $bundleSource 'DreamMangaReader-android-x86_64.apk'); IncludeInManifest=$true }
    )
    $bundleManifest = New-ReleaseFolder `
        -Destination $bundleDestination `
        -Assets $bundleAssets `
        -ReleaseVersion '1.3.1' `
        -ReleaseChannel stable `
        -Gitee $true `
        -GiteePartSizeBytes 2
    Assert-Equal 2 $bundleManifest.schemaVersion 'Gitee manifest schema'
    $chunkedSetup = @($bundleManifest.assets | Where-Object { $_.fileName -ceq 'DreamMangaReader-windows-x64-setup.exe' })[0]
    Assert-Equal 3 @($chunkedSetup.parts).Count 'Gitee setup part count'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $bundleDestination $chunkedSetup.fileName)) 'Gitee chunked logical file omitted'
    $chunkedUniversal = @($bundleManifest.assets | Where-Object { $_.fileName -ceq 'DreamMangaReader-android-universal.apk' })[0]
    Assert-Equal 3 @($chunkedUniversal.parts).Count 'Gitee universal APK part count'
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $bundleDestination $chunkedUniversal.fileName)) 'Gitee chunked universal APK omitted'
    Assert-Equal $true (Test-ReleaseAssetSet -Manifest $bundleManifest -AssetRoot $bundleDestination) 'Gitee chunked bundle integrity'
    Assert-Equal $true (Assert-GiteeReleaseContract -Manifest $bundleManifest -LocalFiles @(Get-ChildItem -LiteralPath $bundleDestination -File)) 'Gitee chunked bundle contract'
    $bundleManifestReadback = Get-Content -LiteralPath (Join-Path $bundleDestination 'dream-manga-reader-update.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $true (Test-ReleaseAssetSet -Manifest $bundleManifestReadback -AssetRoot $bundleDestination) 'Gitee serialized chunked bundle integrity'

    $preparedDestination = Join-Path $tempRoot 'prepared-gitee'
    & (Join-Path $PSScriptRoot '..\准备Gitee发布.ps1') `
        -SourceRoot $bundleSource `
        -Destination $preparedDestination `
        -Version '1.3.1' `
        -Channel stable
    $preparedManifest = Get-Content -LiteralPath (Join-Path $preparedDestination 'dream-manga-reader-update.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 2 $preparedManifest.schemaVersion 'prepared Gitee manifest schema'
    Assert-Equal $true (Assert-GiteeReleaseContract -Manifest $preparedManifest -LocalFiles @(Get-ChildItem -LiteralPath $preparedDestination -File)) 'prepared Gitee bundle contract'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

$retentionFixtures = @(
    [pscustomobject]@{ Id=1; Tag='v1.4.0-beta.2'; Prerelease=$true; SizeBytes=200MB },
    [pscustomobject]@{ Id=2; Tag='v1.3.0'; Prerelease=$false; SizeBytes=200MB },
    [pscustomobject]@{ Id=3; Tag='v1.2.0'; Prerelease=$false; SizeBytes=200MB }
)
$retention = Get-GiteeReleaseRetentionPlan `
    -Releases $retentionFixtures `
    -IncomingTag 'v1.4.0-beta.3' `
    -IncomingPrerelease $true `
    -IncomingSizeBytes 200MB
Assert-Equal $true $retention.Fits 'retention fits default budget'
Assert-Equal 3 @($retention.RetainedTags).Count 'retention keeps three releases'
Assert-Equal $true ($retention.RetainedTags -contains 'v1.3.0') 'retention protects latest stable'
Assert-Equal 1 @($retention.DeleteReleases).Count 'retention deletes oldest release'
Assert-Equal 'v1.2.0' $retention.DeleteReleases[0].Tag 'retention oldest tag'

$tightRetention = Get-GiteeReleaseRetentionPlan `
    -Releases $retentionFixtures `
    -IncomingTag 'v1.4.0-beta.3' `
    -IncomingPrerelease $true `
    -IncomingSizeBytes 200MB `
    -BudgetBytes 450MB
Assert-Equal $true $tightRetention.Fits 'retention shrinks under tight budget'
Assert-Equal 2 @($tightRetention.RetainedTags).Count 'retention keeps incoming and stable'
Assert-Equal 2 @($tightRetention.DeleteReleases).Count 'retention removes optional releases'

$rerunRetention = Get-GiteeReleaseRetentionPlan `
    -Releases (@($retentionFixtures) + @([pscustomobject]@{ Id=4; Tag='v1.4.0-beta.3'; Prerelease=$true; SizeBytes=100MB })) `
    -IncomingTag 'v1.4.0-beta.3' `
    -IncomingPrerelease $true `
    -IncomingSizeBytes 200MB
Assert-Equal $false (@($rerunRetention.DeleteReleases.Tag) -contains 'v1.4.0-beta.3') 'retention never deletes incoming tag'

$protectedRetention = Get-GiteeReleaseRetentionPlan `
    -Releases (@([pscustomobject]@{ Id=5; Tag='manual-release'; Prerelease=$false; SizeBytes=50MB }) + $retentionFixtures) `
    -IncomingTag 'v1.4.0-beta.3' `
    -IncomingPrerelease $true `
    -IncomingSizeBytes 200MB
Assert-Equal $true $protectedRetention.Fits 'retention preserves unknown release'
Assert-Equal $true ($protectedRetention.RetainedTags -contains 'manual-release') 'unknown release remains retained'
Assert-Equal $false (@($protectedRetention.DeleteReleases.Tag) -contains 'manual-release') 'unknown release is never deleted'

$impossibleRetention = Get-GiteeReleaseRetentionPlan `
    -Releases $retentionFixtures `
    -IncomingTag 'v1.4.0-beta.3' `
    -IncomingPrerelease $true `
    -IncomingSizeBytes 200MB `
    -BudgetBytes 350MB
Assert-Equal $false $impossibleRetention.Fits 'retention rejects impossible budget'

Write-Host 'Release.Common tests passed.'
