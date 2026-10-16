param(
    [Parameter(Mandatory = $true)]
    [string]$InputDirectory,
    [string]$OutputDirectory = '',
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$建设单位,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$设计项目名,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$出图日期,
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$设计项目号,
    [string]$CoreConsolePath = 'C:\Program Files\Autodesk\AutoCAD 2022\accoreconsole.exe',
    [string]$AssetDirectory = '',
    [string]$BorderLibrary = '',
    [string]$TitleLibrary = '',
    [string]$DryRunLogDirectory = '',
    [string]$CombinedInventoryDirectory = '',
    [string]$SheetValuesPath = '',
    [string]$SignatureCacheDirectory = '',
    [ValidateSet('Replace', 'UpdateTitle')]
    [string]$OperationMode = 'Replace',
    [ValidateRange(1, 4)]
    [int]$MaxWorkers = 2,
    [ValidateRange(60, 3600)]
    [int]$CoreTimeoutSeconds = 600,
    [switch]$AllowPlaceholderProjectNumber,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$preserveSentinel = '__CFR_PRESERVE__'
$clearSignatureSentinel = '__CFR_CLEAR_SIGNATURE__'
if ($建设单位 -eq $preserveSentinel) { $建设单位 = '' }
if ($设计项目名 -eq $preserveSentinel) { $设计项目名 = '' }
if ($出图日期 -eq $preserveSentinel) { $出图日期 = '' }
if ($设计项目号 -eq $preserveSentinel) { $设计项目号 = '' }
$runStarted = Get-Date

function Test-LikelyDependencyDrawing {
    param([Parameter(Mandatory = $true)][IO.FileInfo]$File)

    $stem = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    if ($stem -match '^(?i:A[012](?:\+(?:0\.)?\d+)?)$') {
        return $true
    }
    if ($stem -match '(?i:baseplan)' -or
        ($stem -match '(?i:base)' -and $stem -match '底图') -or
        $stem -match '^(?:现状)?底图') {
        return $true
    }
    return $false
}

function Test-LikelyFrameXrefDrawing {
    param([Parameter(Mandatory = $true)][IO.FileInfo]$File)
    $stem = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    return $stem -match '^(?i:A[012](?:\+(?:0\.)?\d+)?)$'
}

function Stage-SheetValuesAndSignatures {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$AssetDirectory,
        [Parameter(Mandatory = $true)][Text.Encoding]$OutputEncoding
    )

    $signatureColumns = @(
        '签字图块_审定', '签字图块_审核', '签字图块_校对', '签字图块_设计',
        '签字图块_专业负责人副二', '签字图块_专业负责人副',
        '签字图块_专业负责人', '签字图块_执行设总二',
        '签字图块_执行设总', '签字图块_设计总负责人'
    )
    $text = [IO.File]::ReadAllText($SourcePath, [Text.Encoding]::UTF8)
    $lines = @($text -split "\r?\n" | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) {
        throw "Sheet values file is empty: $SourcePath"
    }
    $headers = @($lines[0].Split("`t"))
    $signatureIndexes = @{}
    foreach ($column in $signatureColumns) {
        $index = [Array]::IndexOf($headers, $column)
        if ($index -ge 0) {
            $signatureIndexes[$column] = $index
        }
    }

    New-Item -ItemType Directory -Force -Path $AssetDirectory | Out-Null
    $assets = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $outputLines = [Collections.Generic.List[string]]::new()
    $outputLines.Add($lines[0])
    $baseDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($SourcePath))

    for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
        $fields = [Collections.Generic.List[string]]::new()
        foreach ($value in $lines[$lineIndex].Split("`t")) {
            $fields.Add($value)
        }
        while ($fields.Count -lt $headers.Count) {
            $fields.Add('')
        }
        foreach ($column in $signatureIndexes.Keys) {
            $index = [int]$signatureIndexes[$column]
            $value = $fields[$index].Trim()
            if ([string]::IsNullOrWhiteSpace($value)) {
                $fields[$index] = ''
                continue
            }
            if ($value -eq $clearSignatureSentinel) {
                continue
            }
            $source = if ([IO.Path]::IsPathRooted($value)) {
                [IO.Path]::GetFullPath($value)
            }
            else {
                [IO.Path]::GetFullPath((Join-Path $baseDirectory $value))
            }
            if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
                [IO.Path]::GetExtension($source) -ne '.dwg') {
                throw "Invalid signature DWG in $column`: $value"
            }
            $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.Substring(0, 12)
            $destination = Join-Path $AssetDirectory ("CFRSIG_{0}.dwg" -f $hash)
            if (-not [string]::Equals(
                $source,
                $destination,
                [StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
            $fields[$index] = $destination
            [void]$assets.Add($destination)
        }
        $outputLines.Add(($fields -join "`t"))
    }

    [IO.File]::WriteAllLines(
        $DestinationPath,
        $outputLines.ToArray(),
        $OutputEncoding
    )
    return @($assets)
}

function Invoke-SignatureNormalization {
    param(
        [Parameter(Mandatory = $true)][string]$CoreConsole,
        [Parameter(Mandatory = $true)][string]$SignatureDwg,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][bool]$Legacy,
        [Parameter(Mandatory = $true)][Text.Encoding]$LegacyTextEncoding,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    if (Test-Path -LiteralPath $ResultPath) {
        Remove-Item -LiteralPath $ResultPath -Force
    }
    $env:FRAME_SIGNATURE_NORMALIZE_RESULT = $ResultPath
    $scriptStem = Join-Path `
        (Split-Path -Parent $ScriptPath) `
        ([IO.Path]::GetFileNameWithoutExtension($ScriptPath))
    $arguments = @(
        '/i', ('"' + $SignatureDwg + '"'),
        '/s', ('"' + $scriptStem + '"'),
        '/l', 'zh-CN'
    )
    $process = Start-Process -FilePath $CoreConsole -ArgumentList $arguments `
        -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "Signature normalization timed out after $TimeoutSeconds seconds: $SignatureDwg"
    }
    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "Signature normalization produced no result: $SignatureDwg"
    }
    $encoding = if ($Legacy) { $LegacyTextEncoding } else { [Text.Encoding]::UTF8 }
    $result = [IO.File]::ReadAllText($ResultPath, $encoding).Trim()
    if (-not $result.StartsWith("OK`t", [StringComparison]::Ordinal)) {
        throw "Signature normalization failed for $SignatureDwg`: $result"
    }
    Write-Host ("Signature normalized: {0} ({1})" -f
        [IO.Path]::GetFileName($SignatureDwg), $result.Substring(3))
}

$coreConsole = $CoreConsolePath
$runId = '{0}_{1}' -f $PID, [Guid]::NewGuid().ToString('N')
$tempBase = Join-Path ([IO.Path]::GetTempPath()) 'CADFrameReplacer'
$tempRoot = Join-Path $tempBase ('replace_' + $runId)
$jobDirectory = Join-Path $tempRoot 'jobs'
$resultDirectory = Join-Path $tempRoot 'results'
if (-not (Test-Path -LiteralPath $coreConsole -PathType Leaf)) {
    throw "AutoCAD Core Console not found: $coreConsole"
}
$coreVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($coreConsole)
if ($coreVersion.FileMajorPart -lt 23 -or
    ($coreVersion.FileMajorPart -eq 23 -and $coreVersion.FileMinorPart -lt 1)) {
    throw "Unsupported AutoCAD Core Console version $($coreVersion.FileVersion). AutoCAD 2020 or newer is required."
}
$legacyMode = $coreVersion.FileMajorPart -lt 24
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$legacyEncoding = [Text.Encoding]::GetEncoding(936)
if ($legacyMode -and [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage -ne 936) {
    throw 'AutoCAD 2020 compatibility requires Windows system locale code page 936 (Simplified Chinese GBK).'
}
if ([string]::IsNullOrWhiteSpace($AssetDirectory)) {
    $AssetDirectory = Join-Path $PSScriptRoot '..\assets'
}
if ([string]::IsNullOrWhiteSpace($TitleLibrary)) {
    $TitleLibrary = Join-Path $PSScriptRoot '..\assets\NEW_TITLE.dwg'
}
$assetDirectorySource = [IO.Path]::GetFullPath($AssetDirectory)
$frameAssetNames = @(
    'NEW_FRAME_A2', 'NEW_FRAME_A2P025', 'NEW_FRAME_A2P05',
    'NEW_FRAME_A2P075', 'NEW_FRAME_A2P1',
    'NEW_FRAME_A1', 'NEW_FRAME_A1P025', 'NEW_FRAME_A1P075',
    'NEW_FRAME_A1P1',
    'NEW_FRAME_A0', 'NEW_FRAME_A0P0125', 'NEW_FRAME_A0P025',
    'NEW_FRAME_A0P0375', 'NEW_FRAME_A0P05'
)
$frameAssetSources = @(
    $frameAssetNames | ForEach-Object {
        Join-Path $assetDirectorySource ($_.ToString() + '.dwg')
    }
)
$titleLibrarySource = [IO.Path]::GetFullPath($TitleLibrary)
$lispSource = Join-Path $PSScriptRoot 'replace_frames.lsp'
$signatureNormalizerSource = Join-Path $PSScriptRoot 'normalize_signature.lsp'
$oldFrameScanSource = Join-Path $PSScriptRoot 'old_frame_scan.lsp'
$workerScript = Join-Path $PSScriptRoot 'replacement_worker.ps1'
$combinedInventoryEnabled = (
    -not $Apply -and
    -not [string]::IsNullOrWhiteSpace($CombinedInventoryDirectory)
)
if ($Apply -and -not [string]::IsNullOrWhiteSpace($CombinedInventoryDirectory)) {
    throw 'CombinedInventoryDirectory is available only in dry-run mode.'
}
$combinedInventoryPath = if ($combinedInventoryEnabled) {
    [IO.Path]::GetFullPath($CombinedInventoryDirectory)
}
else {
    ''
}
$logDirectory = if ($Apply) {
    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $OutputDirectory = Join-Path $PSScriptRoot ("output_" + $stamp)
    }
    Join-Path $OutputDirectory 'logs'
}
else {
    if ([string]::IsNullOrWhiteSpace($DryRunLogDirectory)) {
        Join-Path $PSScriptRoot 'dry_run_logs'
    }
    else {
        [IO.Path]::GetFullPath($DryRunLogDirectory)
    }
}

if (-not (Test-Path -LiteralPath $InputDirectory -PathType Container)) {
    throw "Input directory not found: $InputDirectory"
}
foreach ($required in @(
    $titleLibrarySource,
    $lispSource,
    $signatureNormalizerSource,
    $workerScript) + $frameAssetSources) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required assistant file not found: $required"
    }
}
if ($combinedInventoryEnabled -and
    -not (Test-Path -LiteralPath $oldFrameScanSource -PathType Leaf)) {
    throw "Required assistant file not found: $oldFrameScanSource"
}
if ($Apply -and $OperationMode -eq 'Replace' -and
    -not $AllowPlaceholderProjectNumber -and
    -not [string]::IsNullOrWhiteSpace($设计项目号) -and
    $设计项目号 -match 'X{3,}') {
    throw 'Apply blocked: 设计项目号 is still a placeholder. Supply the real project number.'
}

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $jobDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null
if ($Apply) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
}
if ($combinedInventoryEnabled) {
    New-Item -ItemType Directory -Force -Path $combinedInventoryPath | Out-Null
}

$tempLisp = Join-Path $tempRoot 'replace_frames.lsp'
$tempScript = Join-Path $tempRoot 'run_replace_frames.scr'
$tempAssetDirectory = Join-Path $tempRoot 'frame_assets'
$tempTitle = Join-Path $tempRoot 'NEW_TITLE.dwg'
$tempSheetValues = Join-Path $tempRoot 'sheet_values.tsv'
$tempSignatureDirectory = Join-Path $tempRoot 'signature_assets'
$tempSignatureLisp = Join-Path $tempRoot 'normalize_signature.lsp'
$tempSignatureScript = Join-Path $tempRoot 'normalize_signature.scr'
$tempOldFrameScanLisp = Join-Path $tempRoot 'old_frame_scan_combined.lsp'
$timingRows = [Collections.Generic.List[object]]::new()
$stageStarted = Get-Date
$lispText = [IO.File]::ReadAllText($lispSource, [Text.Encoding]::UTF8)
if ($legacyMode) {
    $lispText = $lispText.Replace('(open path "r" "utf8")', '(open path "r")')
    $lispText = $lispText.Replace('(open log-path "w" "utf8")', '(open log-path "w")')
    [IO.File]::WriteAllText($tempLisp, $lispText, $legacyEncoding)
}
else {
    [IO.File]::WriteAllText($tempLisp, $lispText, $utf8NoBom)
}
if ($combinedInventoryEnabled) {
    $oldFrameScanText = [IO.File]::ReadAllText(
        $oldFrameScanSource,
        [Text.Encoding]::UTF8
    )
    if ($legacyMode) {
        $oldFrameScanText = $oldFrameScanText.Replace(
            '(open out "w" "utf8")',
            '(open out "w")'
        )
        [IO.File]::WriteAllText(
            $tempOldFrameScanLisp,
            $oldFrameScanText,
            $legacyEncoding
        )
    }
    else {
        [IO.File]::WriteAllText(
            $tempOldFrameScanLisp,
            $oldFrameScanText,
            $utf8NoBom
        )
    }
}
New-Item -ItemType Directory -Force -Path $tempAssetDirectory | Out-Null
foreach ($frameAssetSource in $frameAssetSources) {
    Copy-Item -LiteralPath $frameAssetSource `
        -Destination (Join-Path $tempAssetDirectory (
            [IO.Path]::GetFileName($frameAssetSource))) -Force
}
Copy-Item -LiteralPath $titleLibrarySource -Destination $tempTitle -Force
$signatureAssets = @()
if (-not [string]::IsNullOrWhiteSpace($SheetValuesPath)) {
    if (-not (Test-Path -LiteralPath $SheetValuesPath -PathType Leaf)) {
        throw "Sheet values file not found: $SheetValuesPath"
    }
    $signatureAssets = @(
        Stage-SheetValuesAndSignatures `
            -SourcePath $SheetValuesPath `
            -DestinationPath $tempSheetValues `
            -AssetDirectory $tempSignatureDirectory `
            -OutputEncoding $(if ($legacyMode) { $legacyEncoding } else { $utf8NoBom })
    )
}
elseif (Test-Path -LiteralPath $tempSheetValues) {
    Remove-Item -LiteralPath $tempSheetValues -Force
}
$timingRows.Add([pscustomobject]@{
    stage = 'prepare_runtime_assets'
    seconds = [math]::Round(((Get-Date) - $stageStarted).TotalSeconds, 2)
    detail = "signatures=$($signatureAssets.Count)"
})

if ($Apply -and $signatureAssets.Count -gt 0) {
    $normalizationStarted = Get-Date
    $normalizerText = [IO.File]::ReadAllText(
        $signatureNormalizerSource,
        [Text.Encoding]::UTF8
    )
    if ($legacyMode) {
        $normalizerText = $normalizerText.Replace(
            '(open path "w" "utf8")',
            '(open path "w")'
        )
        [IO.File]::WriteAllText($tempSignatureLisp, $normalizerText, $legacyEncoding)
    }
    else {
        [IO.File]::WriteAllText($tempSignatureLisp, $normalizerText, $utf8NoBom)
    }
    $tempSignatureLispForAcad = $tempSignatureLisp.Replace('\', '/')
    [IO.File]::WriteAllLines(
        $tempSignatureScript,
        @(
            '(setvar "SECURELOAD" 0)',
            ('(load "{0}")' -f $tempSignatureLispForAcad),
            '_.QUIT'
        ),
        $utf8NoBom
    )
    if ([string]::IsNullOrWhiteSpace($SignatureCacheDirectory)) {
        $SignatureCacheDirectory = Join-Path (
            [Environment]::GetFolderPath(
                [Environment+SpecialFolder]::LocalApplicationData
            )
        ) 'CADFrameReplacer\signature_cache'
    }
    $normalizerHash = (
        Get-FileHash -LiteralPath $signatureNormalizerSource -Algorithm SHA256
    ).Hash.Substring(0, 12)
    $signatureCachePath = Join-Path (
        [IO.Path]::GetFullPath($SignatureCacheDirectory)
    ) ("normalizer_{0}\acad_{1}" -f
        $normalizerHash,
        $coreVersion.FileMajorPart)
    New-Item -ItemType Directory -Force -Path $signatureCachePath | Out-Null

    $cacheRows = [Collections.Generic.List[object]]::new()
    $cacheHits = 0
    $cacheMisses = 0
    $signatureIndex = 0
    foreach ($signatureAsset in $signatureAssets) {
        $signatureIndex++
        $sourceHash = (
            Get-FileHash -LiteralPath $signatureAsset -Algorithm SHA256
        ).Hash
        $cacheDwg = Join-Path $signatureCachePath (
            'CFRSIG_{0}.dwg' -f $sourceHash.Substring(0, 12)
        )
        $cacheMetadata = $cacheDwg + '.json'
        $cacheValid = $false
        if ((Test-Path -LiteralPath $cacheDwg -PathType Leaf) -and
            (Test-Path -LiteralPath $cacheMetadata -PathType Leaf)) {
            try {
                $metadata = [IO.File]::ReadAllText(
                    $cacheMetadata,
                    [Text.Encoding]::UTF8
                ) | ConvertFrom-Json
                $cachedHash = (
                    Get-FileHash -LiteralPath $cacheDwg -Algorithm SHA256
                ).Hash
                $cacheValid = (
                    [string]$metadata.source_hash -eq $sourceHash -and
                    [string]$metadata.normalized_hash -eq $cachedHash -and
                    [string]$metadata.normalizer_hash -eq $normalizerHash -and
                    [int]$metadata.autocad_major -eq $coreVersion.FileMajorPart
                )
            }
            catch {
                $cacheValid = $false
            }
        }

        $assetStarted = Get-Date
        if ($cacheValid) {
            Copy-Item -LiteralPath $cacheDwg -Destination $signatureAsset -Force
            $cacheHits++
            $cacheStatus = 'hit'
            Write-Host ("Signature cache hit: {0}" -f
                [IO.Path]::GetFileName($signatureAsset))
        }
        else {
            $cacheMisses++
            $cacheStatus = 'normalized'
            $normalizationResult = Join-Path $tempRoot (
                'signature_normalize_{0:D2}.txt' -f $signatureIndex)
            Invoke-SignatureNormalization `
                -CoreConsole $coreConsole `
                -SignatureDwg $signatureAsset `
                -ScriptPath $tempSignatureScript `
                -ResultPath $normalizationResult `
                -Legacy $legacyMode `
                -LegacyTextEncoding $legacyEncoding `
                -TimeoutSeconds $CoreTimeoutSeconds

            $normalizedHash = (
                Get-FileHash -LiteralPath $signatureAsset -Algorithm SHA256
            ).Hash
            Copy-Item -LiteralPath $signatureAsset -Destination $cacheDwg -Force
            $metadata = [ordered]@{
                source_hash = $sourceHash
                normalized_hash = $normalizedHash
                normalizer_hash = $normalizerHash
                autocad_major = $coreVersion.FileMajorPart
                created_utc = [DateTime]::UtcNow.ToString('o')
            } | ConvertTo-Json
            [IO.File]::WriteAllText(
                $cacheMetadata,
                $metadata,
                $utf8NoBom
            )
        }
        $cacheRows.Add([pscustomobject]@{
            signature = [IO.Path]::GetFileName($signatureAsset)
            source_hash = $sourceHash
            status = $cacheStatus
            seconds = [math]::Round(
                ((Get-Date) - $assetStarted).TotalSeconds,
                2
            )
            cache = $cacheDwg
        })
    }
    $cacheRows | Export-Csv -LiteralPath (
        Join-Path $logDirectory 'signature_cache_summary.csv'
    ) -NoTypeInformation -Encoding UTF8
    $timingRows.Add([pscustomobject]@{
        stage = 'normalize_signatures'
        seconds = [math]::Round(
            ((Get-Date) - $normalizationStarted).TotalSeconds,
            2
        )
        detail = "hits=$cacheHits;misses=$cacheMisses"
    })
}

$tempLispForAcad = $tempLisp.Replace('\', '/')
$replacementScriptLines = [Collections.Generic.List[string]]::new()
$replacementScriptLines.Add('(setvar "SECURELOAD" 0)')
$replacementScriptLines.Add(('(load "{0}")' -f $tempLispForAcad))
$replacementScriptLines.Add('(c:REPLACEFRAMES)')
if (-not $Apply) {
    $replacementScriptLines.Add(
        '(setq cfrproxydxf (getenv "FRAME_PROXY_TITLE_DXF"))'
    )
    $replacementScriptLines.Add(
        '(if (and fra:proxy-title-needed cfrproxydxf (/= cfrproxydxf "")) (command "_.DXFOUT" cfrproxydxf 16))'
    )
}
$replacementScriptLines.Add(
    '(setq cfrreplace (getenv "FRAME_REPLACE_DONE"))'
)
$replacementScriptLines.Add(
    '(setq cfrreplacefile (if cfrreplace (open cfrreplace "w") nil))'
)
$replacementScriptLines.Add(
    '(if cfrreplacefile (progn (write-line "OK" cfrreplacefile) (close cfrreplacefile)))'
)
if ($combinedInventoryEnabled) {
    $tempOldFrameScanLispForAcad = $tempOldFrameScanLisp.Replace('\', '/')
    $replacementScriptLines.Add(
        ('(load "{0}")' -f $tempOldFrameScanLispForAcad)
    )
    $replacementScriptLines.Add('(c:OLDFRAMESCAN)')
    $replacementScriptLines.Add(
        '(setq cfrdone (getenv "FRAME_COMBINED_SCAN_DONE"))'
    )
    $replacementScriptLines.Add(
        '(setq cfrfile (if cfrdone (open cfrdone "w") nil))'
    )
    $replacementScriptLines.Add(
        '(if cfrfile (progn (write-line "OK" cfrfile) (close cfrfile)))'
    )
}
$replacementScriptLines.Add('_.QUIT')
[IO.File]::WriteAllLines(
    $tempScript,
    $replacementScriptLines.ToArray(),
    $utf8NoBom
)
$scriptStem = Join-Path $tempRoot 'run_replace_frames'

$files = @(
    Get-ChildItem -LiteralPath $InputDirectory -File -Filter '*.dwg' |
        Sort-Object Name
)
if ($files.Count -eq 0) {
    throw "No DWG files found in input directory: $InputDirectory"
}
$allInputFiles = @($files)
$dependencyFiles = @($allInputFiles | Where-Object {
    Test-LikelyDependencyDrawing -File $_
})
$frameXrefDependencyFiles = @($dependencyFiles | Where-Object {
    Test-LikelyFrameXrefDrawing -File $_
})
if (-not $Apply) {
    $hostCandidates = @($allInputFiles | Where-Object {
        -not (Test-LikelyDependencyDrawing -File $_)
    })
    if ($hostCandidates.Count -gt 0) {
        $files = $hostCandidates
        if ($dependencyFiles.Count -gt 0) {
            $dependencyReport = Join-Path $logDirectory 'dependency_skips.csv'
            $dependencyFiles |
                Select-Object @{Name='file';Expression={$_.Name}},
                    @{Name='status';Expression={'dependency_skipped'}},
                    @{Name='reason';Expression={
                        'Likely frame/base-plan XREF dependency; host DWGs are scanned instead.'
                    }} |
                Export-Csv -LiteralPath $dependencyReport `
                    -NoTypeInformation -Encoding UTF8
            Write-Host (
                "Skipped {0} likely XREF dependency DWG(s); report: {1}" -f
                $dependencyFiles.Count,
                $dependencyReport
            )
        }
    }
}
if ($Apply -and
    -not [string]::IsNullOrWhiteSpace($SheetValuesPath) -and
    (Test-Path -LiteralPath $SheetValuesPath -PathType Leaf)) {
    $selectedDrawingNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($sheetRow in @(
        Import-Csv -LiteralPath $SheetValuesPath -Encoding UTF8 -Delimiter "`t"
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$sheetRow.drawing)) {
            [void]$selectedDrawingNames.Add([string]$sheetRow.drawing)
        }
    }
    $files = @(
        $files | Where-Object { $selectedDrawingNames.Contains($_.Name) }
    )
    if ($files.Count -eq 0) {
        throw 'No scanned drawing remains in the Apply selection.'
    }
}
if ($Apply) {
    # The output directory already identifies the operation.  Keep every DWG
    # file name unchanged so XREF paths, publishing lists and user workflows
    # do not need operation-specific suffix handling.
    $outputSuffix = '.dwg'
    foreach ($file in $files) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $candidate = Join-Path $OutputDirectory ($stem + $outputSuffix)
        if (Test-Path -LiteralPath $candidate) {
            throw "Output already exists; refusing to overwrite: $candidate"
        }
    }
    if ($OperationMode -eq 'UpdateTitle') {
        foreach ($dependencyFile in $frameXrefDependencyFiles) {
            $dependencyOutput = Join-Path $OutputDirectory $dependencyFile.Name
            if (Test-Path -LiteralPath $dependencyOutput) {
                throw "XREF dependency output already exists; refusing to overwrite: $dependencyOutput"
            }
        }
    }
}

if ($Apply -and $OperationMode -eq 'UpdateTitle' -and
    $frameXrefDependencyFiles.Count -gt 0) {
    $copiedDependencies = [Collections.Generic.List[object]]::new()
    foreach ($dependencyFile in $frameXrefDependencyFiles) {
        $dependencyOutput = Join-Path $OutputDirectory $dependencyFile.Name
        Copy-Item -LiteralPath $dependencyFile.FullName `
            -Destination $dependencyOutput -Force
        $copiedDependencies.Add([pscustomobject]@{
            file = $dependencyFile.Name
            status = 'xref_dependency_copied'
            source = $dependencyFile.FullName
            output = $dependencyOutput
        })
    }
    $copiedDependencies | Export-Csv -LiteralPath (
        Join-Path $logDirectory 'xref_dependencies_copied.csv'
    ) -NoTypeInformation -Encoding UTF8
    Write-Host (
        "Copied {0} XREF dependency DWG(s) for UpdateTitle output." -f
        $copiedDependencies.Count
    )
}

$engineName = if ($legacyMode) {
    'AutoCAD-2020-MBCS'
}
else {
    'AutoCAD-2021+-UTF8'
}
$queuedAt = Get-Date
$specs = [Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $files.Count; $index++) {
    $file = $files[$index]
    $number = $index + 1
    $stem = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $workerTemp = Join-Path $tempRoot ('worker_{0:D2}' -f $number)
    $jobPath = Join-Path $jobDirectory ('{0:D2}.clixml' -f $number)
    $resultPath = Join-Path $resultDirectory ('{0:D2}.clixml' -f $number)
    $finalInventory = if ($combinedInventoryEnabled) {
        Join-Path $combinedInventoryPath ('{0:D2}_{1}.tsv' -f $number, $stem)
    }
    else {
        ''
    }
    $outputFile = if ($Apply) {
        Join-Path $OutputDirectory ($stem + $outputSuffix)
    }
    else {
        ''
    }
    $config = [pscustomobject]@{
        Index = $number
        QueuedAt = $queuedAt
        Apply = [bool]$Apply
        CombinedInventoryEnabled = $combinedInventoryEnabled
        CoreConsole = $coreConsole
        Engine = $engineName
        LegacyMode = $legacyMode
        InputFile = $file.FullName
        OutputFile = $outputFile
        ScriptStem = $scriptStem
        TempDirectory = $workerTemp
        TempLog = Join-Path $workerTemp 'replace.tsv'
        ReplaceDone = Join-Path $workerTemp 'replace.done'
        TempInventory = if ($combinedInventoryEnabled) {
            Join-Path $workerTemp 'inventory.tsv'
        }
        else {
            ''
        }
        CombinedDone = if ($combinedInventoryEnabled) {
            Join-Path $workerTemp 'inventory.done'
        }
        else {
            ''
        }
        ProxyTitleDxf = if (-not $Apply) {
            Join-Path $workerTemp 'proxy_title_fields.dxf'
        }
        else {
            ''
        }
        FinalLog = Join-Path $logDirectory (
            '{0:D2}_{1}.tsv' -f $number, $stem
        )
        FinalInventory = $finalInventory
        ResultPath = $resultPath
        AssetDirectory = $tempAssetDirectory
        TitleLibrary = $tempTitle
        SheetValuesPath = if (Test-Path -LiteralPath $tempSheetValues) {
            $tempSheetValues
        }
        else {
            ''
        }
        Owner = $建设单位
        ProjectName = $设计项目名
        ProjectDate = $出图日期
        ProjectNumber = $设计项目号
        OperationMode = $OperationMode
        CoreTimeoutSeconds = $CoreTimeoutSeconds
    }
    $config | Export-Clixml -LiteralPath $jobPath -Encoding UTF8
    $specs.Add([pscustomobject]@{
        Index = $number
        File = $file
        JobPath = $jobPath
        ResultPath = $resultPath
    })
}

$workersStarted = Get-Date
$powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
    $powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
}
$active = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
$nextSpec = 0
$completed = 0

while ($nextSpec -lt $specs.Count -or $active.Count -gt 0) {
    while ($nextSpec -lt $specs.Count -and $active.Count -lt $MaxWorkers) {
        $spec = $specs[$nextSpec]
        $nextSpec++
        $argumentString = (
            '-NoProfile -ExecutionPolicy Bypass -File "{0}" -JobPath "{1}"' -f
            $workerScript,
            $spec.JobPath
        )
        $process = Start-Process -FilePath $powershellExe `
            -ArgumentList $argumentString -PassThru -WindowStyle Hidden
        $active.Add([pscustomobject]@{
            Process = $process
            Spec = $spec
        })
    }

    $finishedAny = $false
    for ($activeIndex = $active.Count - 1; $activeIndex -ge 0; $activeIndex--) {
        $item = $active[$activeIndex]
        $item.Process.Refresh()
        if (-not $item.Process.HasExited) {
            continue
        }
        $finishedAny = $true
        $item.Process.WaitForExit()
        $exitCode = $item.Process.ExitCode
        $item.Process.Dispose()

        if (Test-Path -LiteralPath $item.Spec.ResultPath -PathType Leaf) {
            $result = Import-Clixml -LiteralPath $item.Spec.ResultPath
        }
        else {
            $result = [pscustomobject]@{
                index = [int]$item.Spec.Index
                file = $item.Spec.File.Name
                status = 'failed'
                planned = 0
                replaced = 0
                updated = 0
                skipped_or_error = 1
                seconds = 0
                queue_wait_seconds = 0
                copy_seconds = 0
                core_seconds = 0
                postprocess_seconds = 0
                cad_collect_ms = 0
                cad_replace_ms = 0
                cad_save_ms = 0
                forced_stop_after_completed_log = $false
                timed_out = $false
                save_committed = $false
                engine = $engineName
                output = ''
                inventory = ''
                log = ''
                error = "Replacement worker exited with code $exitCode and produced no result."
            }
        }
        $results.Add($result)
        $completed++
        Write-Host ("[{0}/{1}] {2}: {3}, sheets={4}" -f
            $completed,
            $files.Count,
            $result.file,
            $result.status,
            ([int]$result.planned + [int]$result.replaced + [int]$result.updated))
        if (-not [string]::IsNullOrWhiteSpace([string]$result.error)) {
            Write-Warning ("{0}: {1}" -f $result.file, $result.error)
        }
        $active.RemoveAt($activeIndex)
    }
    if (-not $finishedAny) {
        Start-Sleep -Milliseconds 200
    }
}

$workerWallSeconds = ((Get-Date) - $workersStarted).TotalSeconds
$timingRows.Add([pscustomobject]@{
    stage = 'process_drawings'
    seconds = [math]::Round($workerWallSeconds, 2)
    detail = "files=$($files.Count);workers=$MaxWorkers;apply=$([bool]$Apply)"
})

if (-not $Apply) {
    $proxyRecoveryStarted = Get-Date
    $proxyRecoveryScript = Join-Path $PSScriptRoot 'recover_proxy_title_fields.ps1'
    if (Test-Path -LiteralPath $proxyRecoveryScript -PathType Leaf) {
        foreach ($spec in $specs) {
            try {
                $workerConfig = Import-Clixml -LiteralPath $spec.JobPath
                $proxyDxf = [string]$workerConfig.ProxyTitleDxf
                $planPath = [string]$workerConfig.FinalLog
                if ((Test-Path -LiteralPath $proxyDxf -PathType Leaf) -and
                    (Test-Path -LiteralPath $planPath -PathType Leaf)) {
                    & $proxyRecoveryScript `
                        -DxfPath $proxyDxf `
                        -PlanPath $planPath `
                        -ReportPath ($planPath + '.proxy_title_recovery.csv') `
                        -CandidateReportPath ($planPath + '.proxy_title_candidates.csv')
                }
            }
            catch {
                Write-Warning ("Proxy-title recovery failed for {0}: {1}" -f
                    $spec.File.Name, $_.Exception.Message)
            }
        }
    }
    $timingRows.Add([pscustomobject]@{
        stage = 'recover_proxy_titles'
        seconds = [math]::Round(
            ((Get-Date) - $proxyRecoveryStarted).TotalSeconds,
            2
        )
        detail = "files=$($files.Count)"
    })
}

$orderedResults = @($results | Sort-Object { [int]$_.index })
$summaryPath = Join-Path $logDirectory 'batch_summary.csv'
$orderedResults |
    Select-Object file, status, planned, replaced, updated, skipped_or_error, seconds,
        queue_wait_seconds, copy_seconds, core_seconds, postprocess_seconds,
        cad_collect_ms, cad_replace_ms, cad_save_ms,
        forced_stop_after_completed_log, timed_out, save_committed, engine,
        output, inventory, log, error |
    Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

$failedResults = @(
    $orderedResults | Where-Object status -in @('attention', 'failed')
)
$timingRows.Add([pscustomobject]@{
    stage = 'total'
    seconds = [math]::Round(((Get-Date) - $runStarted).TotalSeconds, 2)
    detail = "failed=$($failedResults.Count)"
})
$timingRows | Export-Csv -LiteralPath (
    Join-Path $logDirectory 'run_timing.csv'
) -NoTypeInformation -Encoding UTF8

$orderedResults
if ($failedResults.Count -gt 0) {
    throw "Frame replacement batch has $($failedResults.Count) failed or incomplete drawing(s). See: $summaryPath"
}

if ($tempRoot.StartsWith(
    $tempBase + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}




