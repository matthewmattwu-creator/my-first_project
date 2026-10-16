param(
    [Parameter(Mandatory = $true)]
    [string]$PlanDirectory,

    [Parameter(Mandatory = $true)]
    [string]$InventoryCsv,

    [Parameter(Mandatory = $true)]
    [string]$ReportCsv
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PlanDirectory -PathType Container)) {
    throw "Plan directory not found: $PlanDirectory"
}
if (-not (Test-Path -LiteralPath $InventoryCsv -PathType Leaf)) {
    throw "Inventory CSV not found: $InventoryCsv"
}

function Get-Key {
    param([string]$Drawing, [string]$Handle)
    $leaf = [IO.Path]::GetFileName([string]$Drawing).Trim().ToUpperInvariant()
    $normalizedHandle = ([string]$Handle).Trim().ToUpperInvariant()
    return $leaf + '|' + $normalizedHandle
}

$available = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($row in @(Import-Csv -LiteralPath $InventoryCsv -Encoding UTF8)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$row.handle)) {
        [void]$available.Add((Get-Key $row.source_file $row.handle))
    }
}

$required = [Collections.Generic.List[object]]::new()
foreach ($planFile in @(
    Get-ChildItem -LiteralPath $PlanDirectory -File -Filter '*.tsv' |
        Sort-Object Name
)) {
    foreach ($row in @(
        Import-Csv -LiteralPath $planFile.FullName -Delimiter "`t" -Encoding UTF8
    )) {
        if ([string]$row.status -notin @('PLANNED', 'REQUIRES_REPLACE')) {
            continue
        }
        foreach ($role in @(
            @{ name = 'FRAME'; property = 'old_frame_handle' },
            @{ name = 'TITLE'; property = 'old_title_handle' }
        )) {
            $handle = [string]$row.($role.property)
            if ([string]::IsNullOrWhiteSpace($handle)) {
                continue
            }
            $key = Get-Key $row.drawing $handle
            $required.Add([pscustomobject]@{
                source_file = [IO.Path]::GetFileName([string]$row.drawing)
                layout = [string]$row.layout
                role = [string]$role.name
                handle = $handle.Trim()
                found = $available.Contains($key)
            })
        }
    }
}

$parent = Split-Path -Parent $ReportCsv
if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
$required | Export-Csv -LiteralPath $ReportCsv -NoTypeInformation -Encoding UTF8
$missing = @($required | Where-Object { -not $_.found })

[pscustomobject]@{
    required_handles = $required.Count
    available_handles = $available.Count
    missing_handles = $missing.Count
    report = $ReportCsv
}

if ($missing.Count -gt 0) {
    Write-Warning (
        'Source inventory is incomplete. Missing planned handles: ' +
        (($missing | ForEach-Object {
            '{0}/{1}/{2}/{3}' -f $_.source_file, $_.layout, $_.role, $_.handle
        }) -join ', ')
    )
    exit 2
}

exit 0
