param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('stable', 'beta')][string]$Channel = 'stable'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Release.Common.ps1')

$sourceRootFull = [System.IO.Path]::GetFullPath($SourceRoot)
$destinationFull = [System.IO.Path]::GetFullPath($Destination)
if (!(Test-Path -LiteralPath $sourceRootFull -PathType Container)) {
    throw "找不到 GitHub 发布附件目录：$sourceRootFull"
}
if ($sourceRootFull.TrimEnd('\', '/') -ceq $destinationFull.TrimEnd('\', '/')) {
    throw 'Gitee 发布目录不能与 GitHub 发布附件目录相同。'
}

$assets = @(
    [pscustomobject]@{
        Platform = 'windows'; Arch = 'x64'; Kind = 'installer'
        FileName = 'DreamMangaReader-windows-x64-setup.exe'
        Path = Join-Path $sourceRootFull 'DreamMangaReader-windows-x64-setup.exe'
        IncludeInManifest = $true
    },
    # 便携版 ZIP 不进 Gitee：更新器在 Windows 上只会选安装器，这 36 MiB 是纯浪费。
    #
    # 通用 APK 也不进 Gitee：它 109 MiB、要切成 3 片，内容与下面三个 ABI 包重复，
    # 占 Gitee 附件总量的 44%。更新器按设备 ABI 逐个匹配，真机永远命中 ABI 专用包；
    # 匹配不上时（冷门 ABI，或平台通道给不出 ABI）会自动换到 GitHub 源取通用包。
    # 两者 GitHub Release 都仍然完整提供。
    [pscustomobject]@{
        Platform = 'android'; Arch = 'armeabi-v7a'; Kind = 'installer'
        FileName = 'DreamMangaReader-android-armeabi-v7a.apk'
        Path = Join-Path $sourceRootFull 'DreamMangaReader-android-armeabi-v7a.apk'
        IncludeInManifest = $true
    },
    [pscustomobject]@{
        Platform = 'android'; Arch = 'arm64-v8a'; Kind = 'installer'
        FileName = 'DreamMangaReader-android-arm64-v8a.apk'
        Path = Join-Path $sourceRootFull 'DreamMangaReader-android-arm64-v8a.apk'
        IncludeInManifest = $true
    },
    [pscustomobject]@{
        Platform = 'android'; Arch = 'x86_64'; Kind = 'installer'
        FileName = 'DreamMangaReader-android-x86_64.apk'
        Path = Join-Path $sourceRootFull 'DreamMangaReader-android-x86_64.apk'
        IncludeInManifest = $true
    }
)

$normalizedVersion = Normalize-ReleaseVersion $Version
$manifest = New-ReleaseFolder `
    -Destination $destinationFull `
    -Assets $assets `
    -ReleaseVersion $normalizedVersion `
    -ReleaseChannel $Channel `
    -Gitee $true

[void](Assert-GiteeReleaseContract `
    -Manifest $manifest `
    -LocalFiles @(Get-ChildItem -LiteralPath $destinationFull -File))
Write-Host "Gitee 发布附件已生成：$destinationFull" -ForegroundColor Green
