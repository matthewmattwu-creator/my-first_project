param(
    [Parameter(Mandatory=$true)][string]$SessionDirectory,
    [Parameter(Mandatory=$true)][string]$LogsDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$sourcePath=Join-Path $SessionDirectory 'source_inventory/frame_inventory.csv'
$outputPath=Join-Path $SessionDirectory 'output_inventory/frame_inventory.csv'
$source=@(Import-Csv $sourcePath); $output=@(Import-Csv $outputPath)
$plans=@(Get-ChildItem -LiteralPath $LogsDirectory -Filter '*.tsv' | Where-Object Name -match '^\d+_' | ForEach-Object {Import-Csv -LiteralPath $_.FullName -Delimiter "`t"} | Where-Object {$_.status -eq 'REPLACED'})
$handles=@($plans.old_title_handle)
$modified=0
foreach($row in $output | Where-Object {$_.old_block -match '^NEW_TITLE(?:_CFR_[0-9]+)?$'}) {
    $match=@($source | Where-Object {$_.source_file -eq $row.source_file -and $_.layout -eq $row.layout -and $_.insertion_point -eq $row.insertion_point -and $handles -contains $_.handle})
    if($match.Count -ne 1) {throw 'Original title transform match failed'}
    $row.x_scale=$match[0].x_scale; $row.y_scale=$match[0].y_scale; $row.rotation=$match[0].rotation
    $modified++
}
$proposed=Join-Path $OutputDirectory 'proposed_output_inventory.csv'
$output | Export-Csv -LiteralPath $proposed -NoTypeInformation -Encoding utf8
$report=Join-Path $OutputDirectory 'proposed_verification.csv'
$args=@{SourceInventoryCsv=$sourcePath;OutputInventoryCsv=$proposed;ReportCsv=$report;建设单位='__CFR_PRESERVE__';设计项目名='__CFR_PRESERVE__';出图日期='__CFR_PRESERVE__';设计项目号='__CFR_PRESERVE__';SheetValuesPath=(Join-Path $LogsDirectory '图签字段配置.tsv');PlanDirectory=$LogsDirectory}
& (Join-Path $repo 'engine/scripts/verify_replacement.ps1') @args | Out-Null
$result=@(Import-Csv $report)
if(@($result | Where-Object result -ne 'PASS').Count -ne 0){throw 'Expected strict verification to pass'}
"PASS proposed metadata: $modified new titles retain original transform; $($result.Count) files pass unchanged verification."
# Negative control: a significant title scale change must still be rejected.
$wrong=$output | Where-Object {$_.old_block -match '^NEW_TITLE'} | Select-Object -First 1
$wrong.x_scale='149.00000000'
$negative=Join-Path $OutputDirectory 'negative_output_inventory.csv'
$output | Export-Csv -LiteralPath $negative -NoTypeInformation -Encoding utf8
$args.OutputInventoryCsv=$negative; $args.ReportCsv=Join-Path $OutputDirectory 'negative_verification.csv'
try {& (Join-Path $repo 'engine/scripts/verify_replacement.ps1') @args | Out-Null}
catch {if($_.Exception.Message -notlike 'CAD assistant verification failed for *'){throw}}
$failures=@(Import-Csv $args.ReportCsv | Where-Object result -eq 'FAIL')
if($failures.Count -eq 0){throw 'Significant negative change was incorrectly accepted'}
'PASS negative control: significant scale change remains a failure.'
'SIMULATION ONLY: no DWG processing or drawing writes; native save/reopen validation is still required.'
