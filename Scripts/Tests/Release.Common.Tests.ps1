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
