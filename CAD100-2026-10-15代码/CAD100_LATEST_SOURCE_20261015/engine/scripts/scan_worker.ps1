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

try {
    New-Item -ItemType Directory -Force -Path $config.TempDirectory | Out-Null
    foreach ($temporary in @($config.TempOutput, $config.TempDone)) {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }

    $env:OLD_FRAME_SCAN_OUTPUT = [string]$config.TempOutput
    $env:OLD_FRAME_SCAN_DONE = [string]$config.TempDone
    $arguments = @(
        '/i', ('"' + [string]$config.InputFile + '"'),
        '/s', ('"' + [string]$config.ScriptStem + '"'),
        '/l', 'zh-CN',
        '/readonly'
    )
    $coreStarted = Get-Date
    $process = Start-Process -FilePath $config.CoreConsole -ArgumentList $arguments `
        -PassThru -WindowStyle Hidden

    $timedOut = $false
    while (-not $process.HasExited) {
        $process.Refresh()
        if ((Test-Path -LiteralPath $config.TempOutput -PathType Leaf) -and
            (Test-Path -LiteralPath $config.TempDone -PathType Leaf)) {
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
                # AutoCAD can exit after the completion marker is written but
                # before Stop-Process runs.  That race is a successful scan,
                # not a failed drawing.
                if ($null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
                    throw
                }
            }
        }
        if ($null -ne (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            $process.WaitForExit()
        }
    }

    $status = if (
        (Test-Path -LiteralPath $config.TempOutput -PathType Leaf) -and
        (Test-Path -LiteralPath $config.TempDone -PathType Leaf)
    ) {
        'scanned'
    }
    else {
        'failed'
    }
    if ($status -eq 'scanned') {
        if ([bool]$config.LegacyMode) {
            $legacyEncoding = [Text.Encoding]::GetEncoding(936)
            $legacyOutputText = [IO.File]::ReadAllText(
                $config.TempOutput,
                $legacyEncoding
            )
            [IO.File]::WriteAllText(
                $config.TempOutput,
                $legacyOutputText,
                [Text.UTF8Encoding]::new($false)
            )
        }
        $inventoryErrors = @(
            Import-Csv -LiteralPath $config.TempOutput -Delimiter "`t" -Encoding UTF8 |
                Where-Object kind -eq 'ERROR'
        )
        if ($inventoryErrors.Count -gt 0) {
            throw "Inventory scanner reported an AutoLISP error: $([string]$inventoryErrors[0].text)"
        }
        Copy-Item -LiteralPath $config.TempOutput `
            -Destination $config.FinalOutput -Force
    }

    $result = [pscustomobject]@{
        index = [int]$config.Index
        file = [IO.Path]::GetFileName([string]$config.InputFile)
        status = $status
        seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        queue_wait_seconds = [math]::Round(
            ($started - [datetime]$config.QueuedAt).TotalSeconds,
            2
        )
        forced_stop_after_output = $forcedStop
        timed_out = $timedOut
        engine = [string]$config.Engine
        inventory = if ($status -eq 'scanned') {
            [string]$config.FinalOutput
        }
        else {
            ''
        }
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
        seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        queue_wait_seconds = [math]::Round(
            ($started - [datetime]$config.QueuedAt).TotalSeconds,
            2
        )
        forced_stop_after_output = $false
        timed_out = $false
        engine = [string]$config.Engine
        inventory = ''
        error = $_.Exception.Message
    }
    Save-WorkerResult -Result $result -Path $config.ResultPath
    exit 1
}
