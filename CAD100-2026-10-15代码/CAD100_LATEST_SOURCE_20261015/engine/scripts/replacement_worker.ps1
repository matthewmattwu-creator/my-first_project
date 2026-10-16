param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath
)

$ErrorActionPreference = 'Stop'

function Save-WorkerResult {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $Result | Export-Clixml -LiteralPath $Path -Encoding UTF8
}

$config = Import-Clixml -LiteralPath $JobPath
$started = Get-Date
$copySeconds = 0.0
$coreSeconds = 0.0
$postprocessSeconds = 0.0
$workingFile = [string]$config.InputFile
$finalOutputFile = [string]$config.OutputFile

try {
    New-Item -ItemType Directory -Force -Path $config.TempDirectory | Out-Null
    $copyWatch = [Diagnostics.Stopwatch]::StartNew()
    if ([bool]$config.Apply) {
        if (Test-Path -LiteralPath $finalOutputFile) {
            throw "Output already exists; refusing to overwrite: $finalOutputFile"
        }
        # AutoCAD 2020 resolves title-frame XREFs reliably only when the
        # companion A0/A1/A2 DWGs are beside the host being processed.  Work
        # in an isolated per-drawing directory, stage only these small frame
        # dependencies, then publish just the saved host DWG to the real
        # output directory.  Baseplan files are deliberately not duplicated.
        $workingDirectory = Join-Path $config.TempDirectory 'working'
        New-Item -ItemType Directory -Force -Path $workingDirectory | Out-Null
        $workingFile = Join-Path $workingDirectory (
            [IO.Path]::GetFileName($finalOutputFile)
        )
        Copy-Item -LiteralPath $config.InputFile -Destination $workingFile
        $sourceDirectory = Split-Path -Parent ([string]$config.InputFile)
        foreach ($dependency in @(
            Get-ChildItem -LiteralPath $sourceDirectory -File -Filter '*.dwg' |
                Where-Object {
                    [IO.Path]::GetFileNameWithoutExtension($_.Name) -match
                        '^(?i:A[012](?:\+(?:0\.)?\d+)?)$'
                }
        )) {
            Copy-Item -LiteralPath $dependency.FullName `
                -Destination (Join-Path $workingDirectory $dependency.Name) `
                -Force
        }
    }
    $copyWatch.Stop()
    $copySeconds = $copyWatch.Elapsed.TotalSeconds

    $initialOutputWriteTimeUtc = if ([bool]$config.Apply) {
        (Get-Item -LiteralPath $workingFile).LastWriteTimeUtc
    }
    else {
        [datetime]::MinValue
    }

    foreach ($temporary in @(
        $config.TempLog,
        $config.ReplaceDone,
        $config.TempInventory,
        $config.CombinedDone,
        $config.ProxyTitleDxf)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$temporary) -and
            (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }

    $env:FRAME_ASSET_DIRECTORY = [string]$config.AssetDirectory
    $env:FRAME_TITLE_LIBRARY = [string]$config.TitleLibrary
    $env:FRAME_TITLE_BLOCK_NAME = 'NEW_TITLE'
    # Each AutoCAD process owns its import files. Shared TEMPPREFIX names
    # otherwise collide when two drawings both import NEW_TITLE_CFR_1.
    $titleImportDirectory = Join-Path $config.TempDirectory 'title-import'
    New-Item -ItemType Directory -Path $titleImportDirectory -Force | Out-Null
    $env:FRAME_TITLE_IMPORT_DIRECTORY = $titleImportDirectory
    $env:FRAME_REPLACE_LOG = [string]$config.TempLog
    $env:FRAME_REPLACE_DONE = [string]$config.ReplaceDone
    $env:FRAME_DRY_RUN = if ([bool]$config.Apply) { '0' } else { '1' }
    $env:FRAME_OPERATION_MODE = if (
        [string]$config.OperationMode -eq 'UpdateTitle'
    ) {
        'UPDATE_TITLE'
    }
    else {
        'REPLACE'
    }
    $env:OLD_FRAME_SCAN_OUTPUT = if ([bool]$config.CombinedInventoryEnabled) {
        [string]$config.TempInventory
    }
    else {
        ''
    }
    $env:FRAME_COMBINED_SCAN_DONE = if ([bool]$config.CombinedInventoryEnabled) {
        [string]$config.CombinedDone
    }
    else {
        ''
    }
    $env:FRAME_FIELD_OWNER = [string]$config.Owner
    $env:FRAME_FIELD_PROJECT_NAME = [string]$config.ProjectName
    $env:FRAME_FIELD_DATE = [string]$config.ProjectDate
    $env:FRAME_FIELD_PROJECT_NUMBER = [string]$config.ProjectNumber
    $env:FRAME_SHEET_VALUES = [string]$config.SheetValuesPath
    $env:FRAME_PROXY_TITLE_DXF = [string]$config.ProxyTitleDxf
    $sourceDirectory = Split-Path -Parent ([string]$config.InputFile)
    if (-not [string]::IsNullOrWhiteSpace($sourceDirectory)) {
        $env:ACAD = if ([string]::IsNullOrWhiteSpace($env:ACAD)) {
            $sourceDirectory
        }
        else {
            $sourceDirectory + ';' + $env:ACAD
        }
    }

    $arguments = @(
        '/i', ('"' + $workingFile + '"'),
        '/s', ('"' + [string]$config.ScriptStem + '"'),
        '/l', 'zh-CN'
    )
    if (-not [bool]$config.Apply) {
        $arguments += '/readonly'
    }

    $coreWatch = [Diagnostics.Stopwatch]::StartNew()
    $coreStarted = Get-Date
    $process = Start-Process -FilePath $config.CoreConsole -ArgumentList $arguments `
        -PassThru -WindowStyle Hidden
    $saveCommitted = -not [bool]$config.Apply
    $timedOut = $false

    while (-not $process.HasExited) {
        $process.Refresh()
        if ([bool]$config.Apply -and
            (Test-Path -LiteralPath $workingFile -PathType Leaf)) {
            $savedItem = Get-Item -LiteralPath $workingFile
            $saveCommitted = (
                $savedItem.Length -gt 0 -and
                $savedItem.LastWriteTimeUtc -gt $initialOutputWriteTimeUtc
            )
        }

        $replacementReady = (
            (Test-Path -LiteralPath $config.TempLog -PathType Leaf) -and
            (Test-Path -LiteralPath $config.ReplaceDone -PathType Leaf)
        )
        $inventoryReady = (
            -not [bool]$config.CombinedInventoryEnabled -or
            (
                (Test-Path -LiteralPath $config.TempInventory -PathType Leaf) -and
                (Test-Path -LiteralPath $config.CombinedDone -PathType Leaf)
            )
        )
        if ($replacementReady -and $inventoryReady -and $saveCommitted) {
            break
        }
        if (((Get-Date) - $coreStarted).TotalSeconds -ge [int]$config.CoreTimeoutSeconds) {
            $timedOut = $true
            break
        }
        Start-Sleep -Milliseconds 200
    }

    $forcedStop = $false
    $process.Refresh()
    if (-not $process.HasExited) {
        $liveProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($null -ne $liveProcess) {
            try {
                Stop-Process -InputObject $liveProcess -Force -ErrorAction Stop
                $forcedStop = $true
            }
            catch {
                # The Core process may exit naturally between the completion
                # marker check and Stop-Process.  Treat that as normal.
                if ($null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
                    throw
                }
            }
        }
        if ($null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            $process.WaitForExit()
        }
    }
    $coreWatch.Stop()
    $coreSeconds = $coreWatch.Elapsed.TotalSeconds

    if ([bool]$config.Apply -and
        (Test-Path -LiteralPath $workingFile -PathType Leaf)) {
        $savedItem = Get-Item -LiteralPath $workingFile
        $saveCommitted = (
            $savedItem.Length -gt 0 -and
            $savedItem.LastWriteTimeUtc -gt $initialOutputWriteTimeUtc
        )
    }
    $finalOutputCommitted = -not [bool]$config.Apply
    if ([bool]$config.Apply -and
        $saveCommitted -and
        (Test-Path -LiteralPath $config.ReplaceDone -PathType Leaf)) {
        Copy-Item -LiteralPath $workingFile -Destination $finalOutputFile
        $finalItem = Get-Item -LiteralPath $finalOutputFile
        $finalOutputCommitted = $finalItem.Length -gt 0
    }

    $postWatch = [Diagnostics.Stopwatch]::StartNew()
    $planned = 0
    $replaced = 0
    $updated = 0
    $skipped = 0
    $collectMs = 0
    $replaceMs = 0
    $saveMs = 0
    $summaryReady = $false
    $summaryConsistent = $false
    $combinedInventoryReady = (
        -not [bool]$config.CombinedInventoryEnabled -or
        (
            (Test-Path -LiteralPath $config.TempInventory -PathType Leaf) -and
            (Test-Path -LiteralPath $config.CombinedDone -PathType Leaf)
        )
    )

    if ([bool]$config.CombinedInventoryEnabled -and $combinedInventoryReady) {
        if ([bool]$config.LegacyMode) {
            $legacyEncoding = [Text.Encoding]::GetEncoding(936)
            $legacyInventoryText = [IO.File]::ReadAllText(
                $config.TempInventory,
                $legacyEncoding
            )
            [IO.File]::WriteAllText(
                $config.TempInventory,
                $legacyInventoryText,
                [Text.UTF8Encoding]::new($false)
            )
        }
        Copy-Item -LiteralPath $config.TempInventory `
            -Destination $config.FinalInventory -Force
    }

    $status = 'failed'
    if (Test-Path -LiteralPath $config.TempLog -PathType Leaf) {
        if ([bool]$config.LegacyMode) {
            $legacyEncoding = [Text.Encoding]::GetEncoding(936)
            $legacyLogText = [IO.File]::ReadAllText(
                $config.TempLog,
                $legacyEncoding
            )
            [IO.File]::WriteAllText(
                $config.TempLog,
                $legacyLogText,
                [Text.UTF8Encoding]::new($false)
            )
        }
        Copy-Item -LiteralPath $config.TempLog -Destination $config.FinalLog -Force
        $logRows = @(Import-Csv -Encoding UTF8 -Delimiter "`t" `
            -LiteralPath $config.TempLog)
        $planned = @($logRows | Where-Object status -eq 'PLANNED').Count
        $replaced = @($logRows | Where-Object status -eq 'REPLACED').Count
        $updated = @($logRows | Where-Object status -eq 'UPDATED').Count
        $skipped = @(
            $logRows | Where-Object status -in @('SKIPPED', 'ERROR')
        ).Count

        $summary = @($logRows | Where-Object status -eq 'SUMMARY' |
            Select-Object -Last 1)
        $summaryReady = $summary.Count -gt 0
        if ($summary.Count -gt 0) {
            $message = [string]$summary[0].message
            $summaryReplaced = -1
            $summarySkipped = -1
            if ($message -match '(?:^|;)replaced=(\d+)') {
                $summaryReplaced = [int]$Matches[1]
            }
            if ($message -match '(?:^|;)skipped=(\d+)') {
                $summarySkipped = [int]$Matches[1]
            }
            if ($message -match '(?:^|;)collect_ms=(\d+)') {
                $collectMs = [int]$Matches[1]
            }
            if ($message -match '(?:^|;)replace_ms=(\d+)') {
                $replaceMs = [int]$Matches[1]
            }
            if ($message -match '(?:^|;)save_ms=(\d+)') {
                $saveMs = [int]$Matches[1]
            }
            $expectedProcessed = if ([bool]$config.Apply) {
                $replaced + $updated
            }
            else {
                $planned
            }
            $summaryConsistent = (
                $summaryReplaced -eq $expectedProcessed -and
                $summarySkipped -eq $skipped
            )
        }

        if ([bool]$config.Apply) {
            $status = if (
                ($replaced -gt 0 -or $updated -gt 0) -and
                $skipped -eq 0 -and
                $summaryReady -and
                $summaryConsistent -and
                $saveCommitted -and
                $finalOutputCommitted -and
                (Test-Path -LiteralPath $config.ReplaceDone -PathType Leaf)
            ) {
                $(if ([string]$config.OperationMode -eq 'UpdateTitle') {
                    'updated'
                }
                else {
                    'replaced'
                })
            }
            else {
                'attention'
            }
        }
        else {
            $dryRunCompleted = (
                $skipped -eq 0 -and
                $summaryReady -and
                $summaryConsistent -and
                $combinedInventoryReady -and
                (Test-Path -LiteralPath $config.ReplaceDone -PathType Leaf)
            )
            $status = if ($dryRunCompleted -and $planned -gt 0) {
                'planned'
            }
            elseif ($dryRunCompleted) {
                'no_frames'
            }
            else {
                'attention'
            }
        }
    }
    $postWatch.Stop()
    $postprocessSeconds = $postWatch.Elapsed.TotalSeconds

    $result = [pscustomobject]@{
        index = [int]$config.Index
        file = [IO.Path]::GetFileName([string]$config.InputFile)
        status = $status
        planned = $planned
        replaced = $replaced
        updated = $updated
        skipped_or_error = $skipped
        seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        queue_wait_seconds = [math]::Round(
            ($started - [datetime]$config.QueuedAt).TotalSeconds,
            2
        )
        copy_seconds = [math]::Round($copySeconds, 2)
        core_seconds = [math]::Round($coreSeconds, 2)
        postprocess_seconds = [math]::Round($postprocessSeconds, 2)
        cad_collect_ms = $collectMs
        cad_replace_ms = $replaceMs
        cad_save_ms = $saveMs
        forced_stop_after_completed_log = $forcedStop
        timed_out = $timedOut
        summary_valid = ($summaryReady -and $summaryConsistent)
        save_committed = $saveCommitted
        engine = [string]$config.Engine
        output = if ([bool]$config.Apply) { $finalOutputFile } else { '' }
        inventory = if (
            [bool]$config.CombinedInventoryEnabled -and
            $combinedInventoryReady
        ) {
            [string]$config.FinalInventory
        }
        else {
            ''
        }
        log = [string]$config.FinalLog
        error = ''
    }
    Save-WorkerResult -Result $result -Path $config.ResultPath
    exit 0
}
catch {
    $result = [pscustomobject]@{
        index = [int]$config.Index
        file = [IO.Path]::GetFileName([string]$config.InputFile)
        status = 'failed'
        planned = 0
        replaced = 0
        updated = 0
        skipped_or_error = 1
        seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        queue_wait_seconds = [math]::Round(
            ($started - [datetime]$config.QueuedAt).TotalSeconds,
            2
        )
        copy_seconds = [math]::Round($copySeconds, 2)
        core_seconds = [math]::Round($coreSeconds, 2)
        postprocess_seconds = [math]::Round($postprocessSeconds, 2)
        cad_collect_ms = 0
        cad_replace_ms = 0
        cad_save_ms = 0
        forced_stop_after_completed_log = $false
        timed_out = $false
        save_committed = $false
        engine = [string]$config.Engine
        output = if ([bool]$config.Apply) { $finalOutputFile } else { '' }
        inventory = ''
        log = [string]$config.FinalLog
        error = $_.Exception.Message
    }
    Save-WorkerResult -Result $result -Path $config.ResultPath
    exit 1
}
