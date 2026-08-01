param(
    [Parameter(Mandatory)][string]$AssetRoot,
    [string]$Owner = 'TypeDreamMoon',
    [string]$Repository = 'DreamMangaReader',
    [string]$TargetBranch = 'main',
    [string]$ReleaseMetadataPath = '',
    [ValidateRange(1, 3)][int]$MaxRetainedReleases = 3,
    [long]$ReleaseBudgetBytes = 850MB,
    [ValidateRange(1, 16)][int]$UploadConcurrency = 8,
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

function Get-GiteeAttachmentDownloadUri {
    param([Parameter(Mandatory)][object]$Remote)

    $downloadUrl = [string]$Remote.browser_download_url
    $downloadUri = [Uri]$downloadUrl
    if (!$downloadUri.IsAbsoluteUri -or
        $downloadUri.Scheme -cne 'https' -or
        ($downloadUri.Host -cne 'gitee.com' -and !$downloadUri.Host.EndsWith('.gitee.com', [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Gitee 附件下载地址无效：$downloadUrl"
    }
    return $downloadUri
}

function Get-GiteeControlFileSha256 {
    param([Parameter(Mandatory)][object]$Remote)

    if ([long]$Remote.size -le 0 -or [long]$Remote.size -gt 1MB) {
        throw "Gitee 校验附件大小无效：$($Remote.name)"
    }
    $downloadUri = Get-GiteeAttachmentDownloadUri -Remote $Remote
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "DreamMangaReader-gitee-control-$([guid]::NewGuid().ToString('N')).download"
    try {
        $null = Invoke-WebRequest -Method Get -Uri $downloadUri -OutFile $tempPath -MaximumRedirection 10 -TimeoutSec 60
        return Get-FileSha256 -Path $tempPath
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
$hashFileName = "DreamMangaReader-v$version-sha256.txt"
$localHashFile = @($localFiles | Where-Object { $_.Name -ceq $hashFileName } | Select-Object -First 1)
if ($localHashFile.Count -ne 1) { throw "Gitee 发布目录缺少唯一 SHA-256 清单：$hashFileName" }
$remoteHashFiles = @($remoteFiles | Where-Object { [string]$_.name -ieq $hashFileName })
if ($remoteHashFiles.Count -gt 1) { throw "Gitee Release 存在重复 SHA-256 清单：$hashFileName" }
$canReuseRemoteFiles = $false
if ($remoteHashFiles.Count -eq 1) {
    $canReuseRemoteFiles = (Get-GiteeControlFileSha256 -Remote $remoteHashFiles[0]) -ceq (Get-FileSha256 -Path $localHashFile[0].FullName)
}
$staleRemoteFiles = if ($remoteFiles.Count -gt 0 -and !$canReuseRemoteFiles) {
    @($remoteFiles)
}
else {
    @(Get-StaleRemoteAttachments -Local $localFiles -Remote $remoteFiles)
}
$usableRemoteFiles = @(Select-ReusableRemoteAttachments -Remote $remoteFiles -Stale $staleRemoteFiles)
$missing = @(Compare-RemoteAttachments -Local $localFiles -Remote $usableRemoteFiles)

Write-Host 'Gitee 发布计划（只允许此仓库）' -ForegroundColor Cyan
Write-Host "目标：$Owner/$Repository / $TargetBranch"
Write-Host "标签：$tag / channel=$($manifest.channel)"
Write-Host "Release：$($releaseMetadata.Name) / prerelease=$($releaseMetadata.Prerelease)"
Write-Host "同标签附件复用：$canReuseRemoteFiles"
Write-Host ("保留：{0} / 预计附件 {1:N2} MiB / 预算 {2:N2} MiB" -f `
    ($retentionPlan.RetainedTags -join ', '),
    ($retentionPlan.ProjectedBytes / 1MB),
    ($retentionPlan.BudgetBytes / 1MB))
foreach ($oldRelease in $retentionPlan.DeleteReleases) {
    Write-Host "- 待删除旧 Release：$($oldRelease.Tag) / $([Math]::Round($oldRelease.SizeBytes / 1MB, 2)) MiB"
}
foreach ($staleFile in $staleRemoteFiles) {
    Write-Host "- 待替换过期附件：$($staleFile.name) / $([Math]::Round([long]$staleFile.size / 1MB, 2)) MiB"
}
foreach ($file in $localFiles) {
    $state = if ($usableRemoteFiles | Where-Object { [string]$_.name -ieq $file.Name }) { '远端已有' } else { '待上传' }
    Write-Host ("- {0} / {1:N2} MiB / {2}" -f $file.Name, ($file.Length / 1MB), $state)
}

if ($DryRun) {
    Write-Host "DryRun 完成：将清理 $($retentionPlan.DeleteReleases.Count) 个旧 Release、替换 $($staleRemoteFiles.Count) 个过期附件，创建或复用 $tag，并上传 $($missing.Count) 个缺失附件；未执行任何远端写入。" -ForegroundColor Green
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

$responseRoot = Join-Path ([System.IO.Path]::GetTempPath()) "DreamMangaReader-gitee-responses-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $responseRoot | Out-Null
try {
    foreach ($staleFile in $staleRemoteFiles) {
        $attachmentId = [long]0
        if ($null -eq $staleFile.PSObject.Properties['id'] -or
            ![long]::TryParse([string]$staleFile.id, [ref]$attachmentId) -or
            $attachmentId -le 0) {
            throw "Gitee 过期附件缺少有效 id：$($staleFile.name)"
        }
        Invoke-GiteeDeleteApi -Uri "$baseUri/releases/$($release.id)/attach_files/$attachmentId"
    }

    $curlCommand = Get-Command 'curl.exe', 'curl' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($missing.Count -gt 0 -and $null -eq $curlCommand) {
        throw 'PATH 中未找到 curl，无法上传 Gitee 附件。'
    }
    if ($missing.Count -gt 0) {
        $curlPath = $curlCommand.Source
        $uploadUri = "$baseUri/releases/$($release.id)/attach_files"
        $giteeToken = $script:GiteeToken
        $actualConcurrency = [Math]::Min($UploadConcurrency, $missing.Count)
        Write-Host "开始并发上传 $($missing.Count) 个附件，并发数：$actualConcurrency" -ForegroundColor Cyan
        foreach ($file in $missing) {
            Write-Host ("- 排队：{0} / {1:N2} MiB" -f $file.Name, ($file.Length / 1MB))
        }

        $uploadResults = @($missing | ForEach-Object -Parallel {
            $ErrorActionPreference = 'Stop'
            $PSNativeCommandUseErrorActionPreference = $false
            $file = $_
            $responsePath = Join-Path $using:responseRoot "$($file.Name).json"
            $curl = $using:curlPath
            $token = $using:giteeToken
            $uri = $using:uploadUri
            & $curl `
                --fail-with-body `
                --silent `
                --show-error `
                --connect-timeout 30 `
                --max-time 7200 `
                --request POST `
                --header 'Accept: application/json' `
                --form "access_token=$token" `
                --form "file=@$($file.FullName);filename=$($file.Name)" `
                --output $responsePath `
                $uri
            if ($LASTEXITCODE -ne 0) {
                throw "Gitee 附件上传失败：$($file.Name)，curl exit code $LASTEXITCODE"
            }
            $response = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$response.name -cne $file.Name -or [long]$response.size -ne $file.Length) {
                throw "Gitee 附件上传响应不符：$($file.Name)"
            }
            [pscustomobject]@{ Name = $file.Name; Size = [long]$file.Length }
        } -ThrottleLimit $actualConcurrency)
        if ($uploadResults.Count -ne $missing.Count) {
            throw "Gitee 附件上传结果数量不符：期望 $($missing.Count)，实际 $($uploadResults.Count)"
        }
    }

    $verifiedRemote = @(Invoke-GiteeReadApi -Uri "$baseUri/releases/$($release.id)/attach_files?per_page=100")
    $remainingStale = @(Get-StaleRemoteAttachments -Local $localFiles -Remote $verifiedRemote)
    if ($remainingStale.Count -ne 0) { throw "Gitee 发布后仍存在 $($remainingStale.Count) 个过期附件。" }
    $stillMissing = @(Compare-RemoteAttachments -Local $localFiles -Remote $verifiedRemote)
    if ($stillMissing.Count -ne 0) { throw "Gitee 发布后仍缺少 $($stillMissing.Count) 个附件。" }
    $remoteManifest = @($verifiedRemote | Where-Object { [string]$_.name -ceq 'dream-manga-reader-update.json' } | Select-Object -First 1)
    if ($remoteManifest.Count -eq 0) { throw 'Gitee Release 缺少远端更新清单。' }
    $verifiedHashFile = @($verifiedRemote | Where-Object { [string]$_.name -ceq $hashFileName } | Select-Object -First 1)
    if ($verifiedHashFile.Count -ne 1 -or
        (Get-GiteeControlFileSha256 -Remote $verifiedHashFile[0]) -cne (Get-FileSha256 -Path $localHashFile[0].FullName)) {
        throw '公开下载的 Gitee SHA-256 清单与本地发布不一致。'
    }
    $remoteManifestUri = Get-GiteeAttachmentDownloadUri -Remote $remoteManifest[0]
    $remoteManifestResponse = Invoke-WebRequest -Method Get -Uri $remoteManifestUri -TimeoutSec 30
    $remoteManifestJson = $remoteManifestResponse.Content | ConvertFrom-Json
    if ([int]$remoteManifestJson.schemaVersion -notin @(1, 2) -or
        [string]$remoteManifestJson.appId -cne 'DreamMangaReader' -or
        [string]$remoteManifestJson.version -cne $version) {
        throw '公开下载的 Gitee 更新清单内容不符合本地发布版本。'
    }
    [void](Assert-GiteeReleaseContract -Manifest $remoteManifestJson -LocalFiles $localFiles)
    $releaseUrl = "https://gitee.com/$Owner/$Repository/releases/tag/$tag"
    Write-Host "Gitee 发布验证完成：$releaseUrl" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $responseRoot) { Remove-Item -LiteralPath $responseRoot -Recurse -Force }
    $script:GiteeToken = $null
}
