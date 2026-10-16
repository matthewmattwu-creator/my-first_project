param(
    [Parameter(Mandatory = $true)]
    [string]$InputDirectory,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'inventory'),

    [string]$CoreConsolePath = 'C:\Program Files\Autodesk\AutoCAD 2020\accoreconsole.exe',

    [ValidateRange(1, 4)]
    [int]$MaxWorkers = 2,

    [ValidateRange(60, 3600)]
    [int]$CoreTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
$runStarted = Get-Date
$coreConsole = $CoreConsolePath

if (-not (Test-Path -LiteralPath $coreConsole -PathType Leaf)) {
    throw "AutoCAD Core Console not found: $coreConsole"
}
$coreVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($coreConsole)
if ($coreVersion.FileMajorPart -lt 23 -or
    ($coreVersion.FileMajorPart -eq 23 -and $coreVersion.FileMinorPart -lt 1)) {
    throw "Unsupported AutoCAD Core Console version $($coreVersion.FileVersion). AutoCAD 2020 or newer is required."
}
$legacyMode = $coreVersion.FileMajorPart -lt 24
$engineName = if ($legacyMode) {
    'AutoCAD-2020-MBCS'
}
else {
    'AutoCAD-2021+-UTF8'
}
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$legacyEncoding = [Text.Encoding]::GetEncoding(936)
if ($legacyMode -and
    [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage -ne 936) {
    throw 'AutoCAD 2020 compatibility requires Windows system locale code page 936 (Simplified Chinese GBK).'
}

if (-not (Test-Path -LiteralPath $InputDirectory -PathType Container)) {
    throw "Input directory not found: $InputDirectory"
}
$files = @(
    Get-ChildItem -LiteralPath $InputDirectory -File -Filter '*.dwg' |
        Sort-Object Name
)
if ($files.Count -eq 0) {
    throw "No DWG files found in input directory: $InputDirectory"
}

$sourceLisp = Join-Path $PSScriptRoot 'old_frame_scan.lsp'
$workerScript = Join-Path $PSScriptRoot 'scan_worker.ps1'
foreach ($required in @($sourceLisp, $workerScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required assistant file not found: $required"
    }
}

$runId = '{0}_{1}' -f $PID, [Guid]::NewGuid().ToString('N')
$tempBase = Join-Path ([IO.Path]::GetTempPath()) 'CADFrameReplacer'
$tempRoot = Join-Path $tempBase ('scan_' + $runId)
$tempLisp = Join-Path $tempRoot 'old_frame_scan.lsp'
$tempScript = Join-Path $tempRoot 'run_old_frame_scan.scr'
$scriptStem = Join-Path $tempRoot 'run_old_frame_scan'
$jobDirectory = Join-Path $tempRoot 'jobs'
$resultDirectory = Join-Path $tempRoot 'results'

New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
New-Item -ItemType Directory -Force -Path $jobDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$lispText = [IO.File]::ReadAllText($sourceLisp, [Text.Encoding]::UTF8)
if ($legacyMode) {
    $lispText = $lispText.Replace('(open out "w" "utf8")', '(open out "w")')
    [IO.File]::WriteAllText($tempLisp, $lispText, $legacyEncoding)
}
else {
    [IO.File]::WriteAllText($tempLisp, $lispText, $utf8NoBom)
}
$tempLispForAcad = $tempLisp.Replace('\', '/')
[IO.File]::WriteAllLines(
    $tempScript,
    @(
        '(setvar "SECURELOAD" 0)',
        ('(load "{0}")' -f $tempLispForAcad),
        '(c:OLDFRAMESCAN)',
        '(setq ofsdone (getenv "OLD_FRAME_SCAN_DONE"))',
        '(setq ofsfile (if ofsdone (open ofsdone "w") nil))',
        '(if ofsfile (progn (write-line "OK" ofsfile) (close ofsfile)))',
        '_.QUIT'
    ),
    $utf8NoBom
)

$specs = [Collections.Generic.List[object]]::new()
$queuedAt = Get-Date
for ($index = 0; $index -lt $files.Count; $index++) {
    $file = $files[$index]
    $number = $index + 1
    $stem = '{0:D2}_{1}' -f $number, [IO.Path]::GetFileNameWithoutExtension($file.Name)
    $workerTemp = Join-Path $tempRoot ('worker_{0:D2}' -f $number)
    $jobPath = Join-Path $jobDirectory ('{0:D2}.clixml' -f $number)
    $resultPath = Join-Path $resultDirectory ('{0:D2}.clixml' -f $number)
    $config = [pscustomobject]@{
        Index = $number
        QueuedAt = $queuedAt
        CoreConsole = $coreConsole
        Engine = $engineName
        LegacyMode = $legacyMode
        InputFile = $file.FullName
        ScriptStem = $scriptStem
        TempDirectory = $workerTemp
        TempOutput = Join-Path $workerTemp 'inventory.tsv'
        TempDone = Join-Path $workerTemp 'inventory.done'
        FinalOutput = Join-Path $OutputDirectory ($stem + '.tsv')
        ResultPath = $resultPath
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
                seconds = 0
                queue_wait_seconds = 0
                forced_stop_after_output = $false
                timed_out = $false
                engine = $engineName
                inventory = ''
                error = "Scan worker exited with code $exitCode and produced no result."
            }
        }

        $results.Add($result)
        $completed++
        Write-Host ("[{0}/{1}] {2}: {3}" -f
            $completed,
            $files.Count,
            $result.file,
            $result.status)
        if (-not [string]::IsNullOrWhiteSpace([string]$result.error)) {
            Write-Warning ("{0}: {1}" -f $result.file, $result.error)
        }
        $active.RemoveAt($activeIndex)
    }
    if (-not $finishedAny) {
        Start-Sleep -Milliseconds 200
    }
}

$orderedResults = @($results | Sort-Object { [int]$_.index })
$summaryPath = Join-Path $OutputDirectory 'scan_summary.csv'
$orderedResults |
    Select-Object file, status, seconds, queue_wait_seconds,
        forced_stop_after_output, timed_out, engine, inventory, error |
    Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8

$failedResults = @($orderedResults | Where-Object status -ne 'scanned')
$wallSeconds = [math]::Round(((Get-Date) - $runStarted).TotalSeconds, 1)
[pscustomobject]@{
    files = $files.Count
    workers = $MaxWorkers
    wall_seconds = $wallSeconds
    sum_worker_seconds = [math]::Round(
        (@($orderedResults | ForEach-Object { [double]$_.seconds }) |
            Measure-Object -Sum).Sum,
        1
    )
    failed = $failedResults.Count
    engine = $engineName
} | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'scan_run_timing.csv') `
    -NoTypeInformation -Encoding UTF8

$orderedResults
if ($failedResults.Count -gt 0) {
    throw "Frame inventory scan has $($failedResults.Count) failed drawing(s). See: $summaryPath"
}

if ($tempRoot.StartsWith(
    $tempBase + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
}
