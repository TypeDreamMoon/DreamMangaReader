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
Assert-Equal 10013 (Get-AndroidUniversalBuildNumber -PubspecBuildNumber 13) 'universal code'
Assert-Equal 10013 (Get-AndroidSplitBaseBuildNumber -PubspecBuildNumber 13) 'split base'
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
    version = '1.3.1'
    assets = @(
        [pscustomobject]@{ platform='windows'; arch='x64'; kind='installer'; fileName='DreamMangaReader-windows-x64-setup.exe' },
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

    foreach ($missingName in $fullGiteeNames) {
        Assert-Throws {
            Assert-GiteeReleaseContract -Manifest $fullGiteeManifest -LocalFiles @($fullGiteeFiles | Where-Object { $_.Name -cne $missingName })
        } "Gitee release missing $missingName"
    }

    $manifestWithUniversal = [pscustomobject]@{
        version = '1.3.1'
        assets = @($fullGiteeManifest.assets) + @(
            [pscustomobject]@{ platform='android'; arch='universal'; kind='installer'; fileName='DreamMangaReader-android-universal.apk' }
        )
    }
    Assert-Throws {
        Assert-GiteeReleaseContract -Manifest $manifestWithUniversal -LocalFiles $fullGiteeFiles
    } 'Gitee manifest with universal APK'

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

    $assetPath = Join-Path $tempRoot 'package.apk'
    [System.IO.File]::WriteAllBytes($assetPath, [byte[]](1, 2, 3))
    Assert-Equal '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81' (Get-FileSha256 $assetPath) 'file SHA'

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
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

Write-Host 'Release.Common tests passed.'
