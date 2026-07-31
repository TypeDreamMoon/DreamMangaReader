param(
    [Parameter(Mandatory)][string]$AssetRoot,
    [string]$Owner = 'TypeDreamMoon',
    [string]$Repository = 'DreamMangaReader',
    [string]$TargetBranch = 'main',
    [switch]$DryRun,
    [switch]$ConfirmPublish
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Release.Common.ps1')

function Get-GiteeToken {
    foreach ($name in @('DREAMMANGAREADER_GITEE_TOKEN', 'GITEE_TOKEN')) {
        foreach ($scope in @('Process', 'User', 'Machine')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if (![string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        }
    }
    return ''
}

function Invoke-GiteeWriteApi {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][hashtable]$Body)

    $Body['access_token'] = $script:GiteeToken
    try {
        return Invoke-RestMethod -Method Post -Uri $Uri -Body $Body -ContentType 'application/x-www-form-urlencoded; charset=utf-8'
    }
    catch {
        throw "Gitee API 写入失败：$Uri；$($_.Exception.Message)"
    }
}

function Get-GiteeReleases {
    param([Parameter(Mandatory)][string]$BaseUri)

    return @(Invoke-RestMethod -Method Get -Uri "$BaseUri/releases?per_page=100" -TimeoutSec 20)
}

[void](Assert-GiteeTarget -Owner $Owner -Repository $Repository)
$assetRootFull = [System.IO.Path]::GetFullPath($AssetRoot)
if (!(Test-Path -LiteralPath $assetRootFull -PathType Container)) {
    throw "找不到 Gitee 发布目录：$assetRootFull"
}
$manifestPath = Join-Path $assetRootFull 'dream-manga-reader-update.json'
if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "发布目录缺少 dream-manga-reader-update.json：$assetRootFull"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
[void](Test-ReleaseAssetSet -Manifest $manifest -AssetRoot $assetRootFull)
$version = Normalize-ReleaseVersion ([string]$manifest.version)
$tag = "v$version"
$localFiles = @(Get-ChildItem -LiteralPath $assetRootFull -File | Sort-Object Name)
if ($localFiles.Count -eq 0) { throw 'Gitee 发布目录没有附件。' }
foreach ($file in $localFiles) {
    [void](Assert-SafeFileName $file.Name)
    if (!(Test-GiteeAttachmentSize -Bytes $file.Length)) {
        throw "Gitee 附件超过 100 MiB：$($file.Name)"
    }
}

$baseUri = "https://gitee.com/api/v5/repos/$Owner/$Repository"
$repo = Invoke-RestMethod -Method Get -Uri $baseUri -TimeoutSec 20
if ([string]$repo.full_name -cne "$Owner/$Repository" -or [string]$repo.default_branch -cne $TargetBranch) {
    throw "Gitee 公开仓库身份不符：$($repo.full_name) / $($repo.default_branch)"
}
$releases = Get-GiteeReleases -BaseUri $baseUri
$sameTag = @($releases | Where-Object { [string]$_.tag_name -ceq $tag } | Select-Object -First 1)
$remoteFiles = @()
if ($sameTag.Count -gt 0) {
    $remoteFiles = @(Invoke-RestMethod -Method Get -Uri "$baseUri/releases/$($sameTag[0].id)/attach_files?per_page=100" -TimeoutSec 20)
}
$missing = @(Compare-RemoteAttachments -Local $localFiles -Remote $remoteFiles)

Write-Host 'Gitee 发布计划（只允许此仓库）' -ForegroundColor Cyan
Write-Host "目标：$Owner/$Repository / $TargetBranch"
Write-Host "标签：$tag / channel=$($manifest.channel)"
foreach ($file in $localFiles) {
    $state = if ($remoteFiles | Where-Object { [string]$_.name -ieq $file.Name }) { '远端已有' } else { '待上传' }
    Write-Host ("- {0} / {1:N2} MiB / {2}" -f $file.Name, ($file.Length / 1MB), $state)
}

if ($DryRun) {
    Write-Host "DryRun 完成：将创建或复用 $tag，并上传 $($missing.Count) 个缺失附件；未执行任何远端写入。" -ForegroundColor Green
    exit 0
}

$script:GiteeToken = Get-GiteeToken
if ([string]::IsNullOrWhiteSpace($script:GiteeToken)) {
    throw '未找到 DREAMMANGAREADER_GITEE_TOKEN 或 GITEE_TOKEN。'
}
if (!$ConfirmPublish) {
    $answer = Read-Host "确认写入 $Owner/$Repository 的 $tag Release？输入 Y 继续"
    if ($answer -cne 'Y') { throw '用户取消发布。' }
}

$release = if ($sameTag.Count -gt 0) {
    $sameTag[0]
}
else {
    Invoke-GiteeWriteApi -Uri "$baseUri/releases" -Body @{
        tag_name = $tag
        name = "DreamMangaReader $tag"
        body = "DreamMangaReader $tag"
        prerelease = ([string]$manifest.channel -ne 'stable').ToString().ToLowerInvariant()
        target_commitish = $TargetBranch
    }
}

$responseFiles = [System.Collections.Generic.List[string]]::new()
try {
    foreach ($file in $missing) {
        $responsePath = Join-Path $assetRootFull "$($file.BaseName).response.json"
        $responseFiles.Add($responsePath)
        $uploadUri = "$baseUri/releases/$($release.id)/attach_files"
        & curl.exe --fail-with-body --show-error --request POST --header 'Accept: application/json' --form "access_token=$script:GiteeToken" --form "file=@$($file.FullName);filename=$($file.Name)" --output $responsePath $uploadUri
        if ($LASTEXITCODE -ne 0) { throw "Gitee 附件上传失败：$($file.Name)，curl exit code $LASTEXITCODE" }
    }

    $verifiedRemote = @(Invoke-RestMethod -Method Get -Uri "$baseUri/releases/$($release.id)/attach_files?per_page=100" -TimeoutSec 20)
    $stillMissing = @(Compare-RemoteAttachments -Local $localFiles -Remote $verifiedRemote)
    if ($stillMissing.Count -ne 0) { throw "Gitee 发布后仍缺少 $($stillMissing.Count) 个附件。" }
    $remoteManifest = @($verifiedRemote | Where-Object { [string]$_.name -ceq 'dream-manga-reader-update.json' } | Select-Object -First 1)
    if ($remoteManifest.Count -eq 0) { throw 'Gitee Release 缺少远端更新清单。' }
    $remoteManifestJson = Invoke-RestMethod -Method Get -Uri ([string]$remoteManifest[0].browser_download_url) -TimeoutSec 30
    if ([int]$remoteManifestJson.schemaVersion -ne 1 -or
        [string]$remoteManifestJson.appId -cne 'DreamMangaReader' -or
        [string]$remoteManifestJson.version -cne $version) {
        throw '公开下载的 Gitee 更新清单内容不符合本地发布版本。'
    }
    $releaseUrl = "https://gitee.com/$Owner/$Repository/releases/tag/$tag"
    Write-Host "Gitee 发布验证完成：$releaseUrl" -ForegroundColor Green
}
finally {
    foreach ($path in $responseFiles) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    $script:GiteeToken = $null
}
