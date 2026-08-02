param(
    [Parameter(Mandatory)][string]$AssetRoot,
    [string]$Owner = 'TypeDreamMoon',
    [string]$Repository = 'DreamMangaReader',
    [string]$TargetBranch = 'main',
    [string]$ReleaseMetadataPath = '',
    [ValidateRange(1, 3)][int]$MaxRetainedReleases = 3,
    [long]$ReleaseBudgetBytes = 850MB,
    [ValidateRange(1, 16)][int]$UploadConcurrency = 8,
    [ValidateRange(1, 8)][int]$UploadAttempts = 4,
    [ValidateRange(60, 3600)][int]$UploadMaxSeconds = 1800,
    [ValidateRange(1, 600)][int]$UploadStallSeconds = 60,
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
        [int]$TimeoutSec = 60,
        [int]$Attempts = 3
    )

    $request = @{
        Method = 'Get'
        Uri = $Uri
        TimeoutSec = $TimeoutSec
    }
    if (![string]::IsNullOrWhiteSpace($script:GiteeToken)) {
        $request['Headers'] = @{ Authorization = "token $script:GiteeToken" }
    }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            # 必须先落到变量再 return：直接透传 Invoke-RestMethod 的输出时，
            # JSON 数组会被当成单个对象传出去，调用方 @() 之后拿到的是嵌套数组，
            # 一旦远端附件多于一个，[long]$file.size 就会炸。
            $response = Invoke-RestMethod @request
            return $response
        }
        catch {
            # 跨境访问 Gitee 抖动是常态，只有最后一次才让整条流水线失败。
            if ($attempt -eq $Attempts) {
                throw "Gitee API 读取失败：$Uri；$($_.Exception.Message)"
            }
            Write-Host ("Gitee API 读取重试 {0}/{1}：{2}" -f $attempt, $Attempts, $Uri) -ForegroundColor Yellow
            Start-Sleep -Seconds (5 * $attempt)
        }
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
        $null = Invoke-WebRequest -Method Get -Uri $downloadUri -OutFile $tempPath `
            -MaximumRedirection 10 -TimeoutSec 60 -MaximumRetryCount 3 -RetryIntervalSec 5
        return Get-FileSha256 -Path $tempPath
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

# 单个附件的上传闭包：跨境链路会静默失速，所以每次尝试都带失速阈值和逐文件进度，
# 并在重试前先与远端对账——响应丢失但服务端其实收下的情况会留下同名附件，
# 直接重传就会变成重复附件，后续对账立刻炸掉。
# 会被 ForEach-Object -Parallel 以源码文本注入 runspace，因此不得引用外层作用域。
function Invoke-GiteeAttachmentUpload {
    param(
        [Parameter(Mandatory)][object]$File,
        [Parameter(Mandatory)][string]$CurlPath,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$AttachFilesUri,
        [Parameter(Mandatory)][string]$ResponseRoot,
        [int]$Attempts = 4,
        [int]$ConnectTimeoutSec = 30,
        [int]$MaxTimeSec = 1800,
        [int]$StallBytesPerSecond = 4096,
        [int]$StallSeconds = 60
    )

    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $sizeMiB = $File.Length / 1MB
    $listUri = "$AttachFilesUri`?per_page=100"
    $lastError = ''

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) {
            $landed = @()
            try {
                $remote = @(Invoke-RestMethod -Method Get -Uri $listUri `
                    -Headers @{ Authorization = "token $Token" } -TimeoutSec 60)
                $landed = @($remote | Where-Object { [string]$_.name -ceq [string]$File.Name })
            }
            catch {
                $landed = @()
            }
            if ($landed.Count -eq 1 -and [long]$landed[0].size -eq [long]$File.Length) {
                Write-Host ("= {0} / {1:N2} MiB / 上一次尝试实际已落地，跳过" -f $File.Name, $sizeMiB)
                return [pscustomobject]@{ Name = [string]$File.Name; Size = [long]$File.Length }
            }
            foreach ($orphan in $landed) {
                $orphanId = [long]0
                if (![long]::TryParse([string]$orphan.id, [ref]$orphanId) -or $orphanId -le 0) {
                    throw "Gitee 残留附件缺少有效 id：$($File.Name)"
                }
                try {
                    $null = Invoke-RestMethod -Method Delete -Uri "$AttachFilesUri/$orphanId" `
                        -Body @{ access_token = $Token } `
                        -ContentType 'application/x-www-form-urlencoded; charset=utf-8'
                }
                catch {
                    throw "Gitee 残留附件清理失败：$($File.Name)；$($_.Exception.Message)"
                }
            }
            Start-Sleep -Seconds ([Math]::Min(30, 5 * ($attempt - 1)))
        }

        $responsePath = Join-Path $ResponseRoot "$($File.Name).attempt$attempt.json"
        $startedAt = [datetime]::UtcNow
        Write-Host ("↑ {0} / {1:N2} MiB / 第 {2}/{3} 次" -f $File.Name, $sizeMiB, $attempt, $Attempts)
        & $CurlPath `
            --fail-with-body `
            --silent `
            --show-error `
            --connect-timeout $ConnectTimeoutSec `
            --max-time $MaxTimeSec `
            --speed-limit $StallBytesPerSecond `
            --speed-time $StallSeconds `
            --request POST `
            --header 'Accept: application/json' `
            --header 'Expect:' `
            --form "access_token=$Token" `
            --form "file=@$($File.FullName);filename=$($File.Name)" `
            --output $responsePath `
            $AttachFilesUri
        $exitCode = $LASTEXITCODE
        $elapsedSeconds = [Math]::Max(([datetime]::UtcNow - $startedAt).TotalSeconds, 0.001)

        if ($exitCode -eq 0) {
            $response = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$response.name -cne [string]$File.Name -or [long]$response.size -ne [long]$File.Length) {
                throw "Gitee 附件上传响应不符：$($File.Name)"
            }
            Write-Host ("√ {0} / {1:N2} MiB / {2:N0} 秒 / {3:N2} MiB/s" -f `
                $File.Name, $sizeMiB, $elapsedSeconds, ($sizeMiB / $elapsedSeconds)) -ForegroundColor Green
            return [pscustomobject]@{ Name = [string]$File.Name; Size = [long]$File.Length }
        }

        $lastError = switch ($exitCode) {
            28 { "curl exit 28：连接超时或传输速率低于 $StallBytesPerSecond B/s 持续 $StallSeconds 秒" }
            default { "curl exit $exitCode" }
        }
        Write-Host ("× {0} / 第 {1}/{2} 次失败 / {3:N0} 秒 / {4}" -f `
            $File.Name, $attempt, $Attempts, $elapsedSeconds, $lastError) -ForegroundColor Yellow
    }
    throw "Gitee 附件上传失败：$($File.Name)，$Attempts 次尝试均未成功（$lastError）"
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
# 整个 if 必须包在 @() 里：空数组作为语句输出会被枚举成零个对象，
# 于是 $staleRemoteFiles 会变成 $null 而不是空集合，
# 后面 -Stale 的 Mandatory 参数就会拒绝绑定。远端已全部对齐时正是这条路径。
$staleRemoteFiles = @(if ($remoteFiles.Count -gt 0 -and !$canReuseRemoteFiles) {
    @($remoteFiles)
}
else {
    @(Get-StaleRemoteAttachments -Local $localFiles -Remote $remoteFiles)
})
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
        $uploadFunctionText = ${function:Invoke-GiteeAttachmentUpload}.ToString()
        $uploadOptions = @{
            CurlPath = $curlPath
            Token = $giteeToken
            AttachFilesUri = $uploadUri
            ResponseRoot = $responseRoot
            Attempts = $UploadAttempts
            MaxTimeSec = $UploadMaxSeconds
            StallSeconds = $UploadStallSeconds
        }

        # 上传顺序决定了中断后能不能续传：
        #   1. SHA-256 清单先走——它是「远端这批附件属于本次构建」的身份标记，
        #      有了它，重跑时按名称+大小逐个复用已传完的分片，而不是整体作废重传；
        #   2. 二进制按体积从大到小并发，避免大文件拖尾；
        #   3. dream-manga-reader-update.json 最后走——更新器读的是它，
        #      它落地才意味着这个 Release 对客户端生效。
        $hashUploads = @($missing | Where-Object { [string]$_.Name -ceq $hashFileName })
        $manifestUploads = @($missing | Where-Object { [string]$_.Name -ceq 'dream-manga-reader-update.json' })
        $binaryUploads = @($missing |
            Where-Object { [string]$_.Name -cne $hashFileName -and [string]$_.Name -cne 'dream-manga-reader-update.json' } |
            Sort-Object -Property Length -Descending)
        $actualConcurrency = [Math]::Max(1, [Math]::Min($UploadConcurrency, $binaryUploads.Count))
        $uploadedBytes = [long]0
        foreach ($file in $missing) { $uploadedBytes += [long]$file.Length }
        Write-Host ("开始上传 {0} 个附件 / 共 {1:N2} MiB / 二进制并发数：{2} / 每个附件最多 {3} 次尝试" -f `
            $missing.Count, ($uploadedBytes / 1MB), $actualConcurrency, $UploadAttempts) -ForegroundColor Cyan
        foreach ($file in @($hashUploads) + @($binaryUploads) + @($manifestUploads)) {
            Write-Host ("- 排队：{0} / {1:N2} MiB" -f $file.Name, ($file.Length / 1MB))
        }

        $uploadStartedAt = [datetime]::UtcNow
        $uploadResults = [System.Collections.Generic.List[object]]::new()
        foreach ($file in $hashUploads) {
            $uploadResults.Add((Invoke-GiteeAttachmentUpload -File $file @uploadOptions))
        }
        if ($binaryUploads.Count -gt 0) {
            $parallelResults = @($binaryUploads | ForEach-Object -Parallel {
                ${function:Invoke-GiteeAttachmentUpload} = $using:uploadFunctionText
                Invoke-GiteeAttachmentUpload -File $_ @using:uploadOptions
            } -ThrottleLimit $actualConcurrency)
            $uploadResults.AddRange($parallelResults)
        }
        foreach ($file in $manifestUploads) {
            $uploadResults.Add((Invoke-GiteeAttachmentUpload -File $file @uploadOptions))
        }
        $uploadSeconds = [Math]::Max(([datetime]::UtcNow - $uploadStartedAt).TotalSeconds, 0.001)
        Write-Host ("上传合计：{0:N2} MiB / {1:N0} 秒 / 平均 {2:N2} MiB/s" -f `
            ($uploadedBytes / 1MB), $uploadSeconds, (($uploadedBytes / 1MB) / $uploadSeconds)) -ForegroundColor Cyan
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
