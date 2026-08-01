param(
    [Parameter(Mandatory)][string]$AssetRoot,
    [string]$Owner = 'TypeDreamMoon',
    [string]$Repository = 'DreamMangaReader',
    [string]$TargetBranch = 'main',
    [string]$ReleaseMetadataPath = '',
    [ValidateRange(1, 3)][int]$MaxRetainedReleases = 3,
    [long]$ReleaseBudgetBytes = 850MB,
    [switch]$DryRun,
    [switch]$ConfirmPublish
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Release.Common.ps1')

function Get-GiteeToken {
    foreach ($name in @('DREAMMANGAREADER_GITEE_TOKEN', 'GITEE_TOKEN')) {
        foreach ($scope in @('Process', 'User', 'Machine')) {
            try {
                $value = [Environment]::GetEnvironmentVariable($name, $scope)
            }
            catch [System.PlatformNotSupportedException] {
                $value = $null
            }
            if (![string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
        }
    }
    return ''
}

function Invoke-GiteeReadApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSec = 20
    )

    $request = @{
        Method = 'Get'
        Uri = $Uri
        TimeoutSec = $TimeoutSec
    }
    if (![string]::IsNullOrWhiteSpace($script:GiteeToken)) {
        $request['Headers'] = @{ Authorization = "token $script:GiteeToken" }
    }
    try {
        return Invoke-RestMethod @request
    }
    catch {
        throw "Gitee API 读取失败：$Uri；$($_.Exception.Message)"
    }
}

function Invoke-GiteeWriteApi {
    param(
        [Parameter(Mandatory)][ValidateSet('Post', 'Patch')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Body
    )

    $Body['access_token'] = $script:GiteeToken
    try {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Body $Body -ContentType 'application/x-www-form-urlencoded; charset=utf-8'
    }
    catch {
        throw "Gitee API 写入失败：$Uri；$($_.Exception.Message)"
    }
}

function Get-GiteeReleases {
    param([Parameter(Mandatory)][string]$BaseUri)

    return @(Invoke-GiteeReadApi -Uri "$BaseUri/releases?per_page=100&direction=desc")
}

function Invoke-GiteeDeleteApi {
    param([Parameter(Mandatory)][string]$Uri)

    try {
        $null = Invoke-RestMethod `
            -Method Delete `
            -Uri $Uri `
            -Body @{ access_token = $script:GiteeToken } `
            -ContentType 'application/x-www-form-urlencoded; charset=utf-8'
    }
    catch {
        throw "Gitee API 删除失败：$Uri；$($_.Exception.Message)"
    }
}

$script:RemoteAttachmentHashes = @{}
function Get-GiteeAttachmentSha256 {
    param([Parameter(Mandatory)][object]$Remote)

    $downloadUrl = [string]$Remote.browser_download_url
    $downloadUri = [Uri]$downloadUrl
    if (!$downloadUri.IsAbsoluteUri -or
        $downloadUri.Scheme -cne 'https' -or
        ($downloadUri.Host -cne 'gitee.com' -and !$downloadUri.Host.EndsWith('.gitee.com', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Gitee 附件下载地址无效：$downloadUrl"
    }
    if ($script:RemoteAttachmentHashes.ContainsKey($downloadUrl)) {
        return $script:RemoteAttachmentHashes[$downloadUrl]
    }

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "DreamMangaReader-gitee-$([guid]::NewGuid().ToString('N')).download"
    try {
        $null = Invoke-WebRequest -Method Get -Uri $downloadUri -OutFile $tempPath -MaximumRedirection 10 -TimeoutSec 300
        $hash = Get-FileSha256 -Path $tempPath
        $script:RemoteAttachmentHashes[$downloadUrl] = $hash
        return $hash
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
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
$releaseMetadata = Resolve-GiteeReleaseMetadata -Version $version -Channel ([string]$manifest.channel) -MetadataPath $ReleaseMetadataPath
$localFiles = @(Get-ChildItem -LiteralPath $assetRootFull -File | Sort-Object Name)
if ($localFiles.Count -eq 0) { throw 'Gitee 发布目录没有附件。' }
[void](Assert-GiteeReleaseContract -Manifest $manifest -LocalFiles $localFiles)
foreach ($file in $localFiles) {
    [void](Assert-SafeFileName $file.Name)
    if (!(Test-GiteeAttachmentSize -Bytes $file.Length)) {
        throw "Gitee 附件超过 100 MiB：$($file.Name)"
    }
}

$script:GiteeToken = Get-GiteeToken
$baseUri = "https://gitee.com/api/v5/repos/$Owner/$Repository"
$repo = Invoke-GiteeReadApi -Uri $baseUri
if ([string]$repo.full_name -cne "$Owner/$Repository" -or [string]$repo.default_branch -cne $TargetBranch) {
    throw "Gitee 公开仓库身份不符：$($repo.full_name) / $($repo.default_branch)"
}
$releases = Get-GiteeReleases -BaseUri $baseUri
$releaseRecords = [System.Collections.Generic.List[object]]::new()
$remoteFilesByReleaseId = @{}
foreach ($remoteRelease in $releases) {
    $idProperty = $remoteRelease.PSObject.Properties['id']
    $releaseId = [long]0
    if ($null -eq $idProperty -or ![long]::TryParse([string]$idProperty.Value, [ref]$releaseId) -or $releaseId -le 0) {
        throw "Gitee Release 缺少有效 id：$($remoteRelease.tag_name)"
    }
    $releaseFiles = @(Invoke-GiteeReadApi -Uri "$baseUri/releases/$releaseId/attach_files?per_page=100")
    $remoteFilesByReleaseId[[string]$releaseId] = $releaseFiles
    $releaseSizeBytes = [long]0
    foreach ($releaseFile in $releaseFiles) { $releaseSizeBytes += [long]$releaseFile.size }
    $releaseRecords.Add([pscustomobject]@{
        Id = $releaseId
        Tag = [string]$remoteRelease.tag_name
        Prerelease = $remoteRelease.prerelease -eq $true
        SizeBytes = $releaseSizeBytes
        Remote = $remoteRelease
    })
}
$localSizeBytes = [long]0
foreach ($localFile in $localFiles) { $localSizeBytes += [long]$localFile.Length }
$retentionPlan = Get-GiteeReleaseRetentionPlan `
    -Releases $releaseRecords.ToArray() `
    -IncomingTag $tag `
    -IncomingPrerelease $releaseMetadata.Prerelease `
    -IncomingSizeBytes $localSizeBytes `
    -MaxReleaseCount $MaxRetainedReleases `
    -BudgetBytes $ReleaseBudgetBytes
if (!$retentionPlan.Fits) {
    throw "Gitee Release 保留计划不可执行：$($retentionPlan.Reason)"
}
$sameTag = @($releases | Where-Object { [string]$_.tag_name -ceq $tag } | Select-Object -First 1)
$remoteFiles = @()
if ($sameTag.Count -gt 0) {
    $remoteFiles = @($remoteFilesByReleaseId[[string]$sameTag[0].id])
}
$missing = @(Compare-RemoteAttachments -Local $localFiles -Remote $remoteFiles -GetRemoteSha256 {
    param($remote)
    Get-GiteeAttachmentSha256 -Remote $remote
})

Write-Host 'Gitee 发布计划（只允许此仓库）' -ForegroundColor Cyan
Write-Host "目标：$Owner/$Repository / $TargetBranch"
Write-Host "标签：$tag / channel=$($manifest.channel)"
Write-Host "Release：$($releaseMetadata.Name) / prerelease=$($releaseMetadata.Prerelease)"
Write-Host ("保留：{0} / 预计附件 {1:N2} MiB / 预算 {2:N2} MiB" -f `
    ($retentionPlan.RetainedTags -join ', '),
    ($retentionPlan.ProjectedBytes / 1MB),
    ($retentionPlan.BudgetBytes / 1MB))
foreach ($oldRelease in $retentionPlan.DeleteReleases) {
    Write-Host "- 待删除旧 Release：$($oldRelease.Tag) / $([Math]::Round($oldRelease.SizeBytes / 1MB, 2)) MiB"
}
foreach ($file in $localFiles) {
    $state = if ($remoteFiles | Where-Object { [string]$_.name -ieq $file.Name }) { '远端已有' } else { '待上传' }
    Write-Host ("- {0} / {1:N2} MiB / {2}" -f $file.Name, ($file.Length / 1MB), $state)
}

if ($DryRun) {
    Write-Host "DryRun 完成：将清理 $($retentionPlan.DeleteReleases.Count) 个旧 Release，创建或复用 $tag，并上传 $($missing.Count) 个缺失附件；未执行任何远端写入。" -ForegroundColor Green
    $script:GiteeToken = $null
    exit 0
}

if ([string]::IsNullOrWhiteSpace($script:GiteeToken)) {
    throw '未找到 DREAMMANGAREADER_GITEE_TOKEN 或 GITEE_TOKEN。'
}
if (!$ConfirmPublish) {
    $answer = Read-Host "确认清理旧版本并写入 $Owner/$Repository 的 $tag Release？输入 Y 继续"
    if ($answer -cne 'Y') { throw '用户取消发布。' }
}

$releaseBody = @{
    tag_name = $tag
    name = $releaseMetadata.Name
    body = $releaseMetadata.Body
    prerelease = $releaseMetadata.Prerelease.ToString().ToLowerInvariant()
}

foreach ($oldRelease in $retentionPlan.DeleteReleases) {
    Invoke-GiteeDeleteApi -Uri "$baseUri/releases/$($oldRelease.Id)"
}
$release = if ($sameTag.Count -gt 0) {
    if ($releaseMetadata.External) {
        Invoke-GiteeWriteApi -Method Patch -Uri "$baseUri/releases/$($sameTag[0].id)" -Body $releaseBody
    }
    else {
        $sameTag[0]
    }
}
else {
    $releaseBody['target_commitish'] = $TargetBranch
    Invoke-GiteeWriteApi -Method Post -Uri "$baseUri/releases" -Body $releaseBody
}

$responseFiles = [System.Collections.Generic.List[string]]::new()
try {
    $curlCommand = Get-Command 'curl.exe', 'curl' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($missing.Count -gt 0 -and $null -eq $curlCommand) {
        throw 'PATH 中未找到 curl，无法上传 Gitee 附件。'
    }
    foreach ($file in $missing) {
        $responsePath = Join-Path $assetRootFull "$($file.BaseName).response.json"
        $responseFiles.Add($responsePath)
        $uploadUri = "$baseUri/releases/$($release.id)/attach_files"
        & $curlCommand.Source --fail-with-body --show-error --request POST --header 'Accept: application/json' --form "access_token=$script:GiteeToken" --form "file=@$($file.FullName);filename=$($file.Name)" --output $responsePath $uploadUri
        if ($LASTEXITCODE -ne 0) { throw "Gitee 附件上传失败：$($file.Name)，curl exit code $LASTEXITCODE" }
    }

    $verifiedRemote = @(Invoke-GiteeReadApi -Uri "$baseUri/releases/$($release.id)/attach_files?per_page=100")
    $stillMissing = @(Compare-RemoteAttachments -Local $localFiles -Remote $verifiedRemote -GetRemoteSha256 {
        param($remote)
        Get-GiteeAttachmentSha256 -Remote $remote
    })
    if ($stillMissing.Count -ne 0) { throw "Gitee 发布后仍缺少 $($stillMissing.Count) 个附件。" }
    $remoteManifest = @($verifiedRemote | Where-Object { [string]$_.name -ceq 'dream-manga-reader-update.json' } | Select-Object -First 1)
    if ($remoteManifest.Count -eq 0) { throw 'Gitee Release 缺少远端更新清单。' }
    $remoteManifestResponse = Invoke-WebRequest -Method Get -Uri ([string]$remoteManifest[0].browser_download_url) -TimeoutSec 30
    $remoteManifestJson = $remoteManifestResponse.Content | ConvertFrom-Json
    if ([int]$remoteManifestJson.schemaVersion -notin @(1, 2) -or
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
