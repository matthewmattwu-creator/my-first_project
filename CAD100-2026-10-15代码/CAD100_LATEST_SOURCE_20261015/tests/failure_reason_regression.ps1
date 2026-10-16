param(
    [Parameter(Mandatory=$true)][string]$SessionDirectory,
    [Parameter(Mandatory=$true)][string]$LogsDirectory,
    [Parameter(Mandatory=$true)][string]$ReportPath
)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$baseline=@(Import-Csv (Join-Path $LogsDirectory '最终验收报告.csv'))
try {
    & (Join-Path $repo 'engine/scripts/verify_replacement.ps1') `
        -SourceInventoryCsv (Join-Path $SessionDirectory 'source_inventory/frame_inventory.csv') `
        -OutputInventoryCsv (Join-Path $SessionDirectory 'output_inventory/frame_inventory.csv') `
        -ReportCsv $ReportPath -建设单位 '__CFR_PRESERVE__' `
        -设计项目名 '__CFR_PRESERVE__' -出图日期 '__CFR_PRESERVE__' `
        -设计项目号 '__CFR_PRESERVE__' `
        -SheetValuesPath (Join-Path $LogsDirectory '图签字段配置.tsv') `
        -PlanDirectory $LogsDirectory | Out-Null
} catch {
    if ($_.Exception.Message -notlike 'CAD assistant verification failed for *') { throw }
}
$actual=@(Import-Csv $ReportPath)
if($baseline.Count -ne $actual.Count) {throw 'Report count changed'}
foreach($before in $baseline) {
    $after=@($actual | Where-Object file -eq $before.file)
    if($after.Count -ne 1) {throw 'Missing or duplicate file'}
    foreach($column in $before.PSObject.Properties.Name) {
        if($column -eq 'failure_reason') {continue}
        if($before.$column -ne $after[0].$column) {throw "Acceptance changed: $($before.file)/$column"}
    }
    if($after[0].result -eq 'FAIL' -and [string]::IsNullOrWhiteSpace($after[0].failure_reason)) {
        throw 'Failure reason missing'
    }
}
$assembly=[Reflection.Assembly]::LoadFrom((Join-Path $repo 'dist/CAD-100/CadProcessingCore.dll'))
$type=$assembly.GetType('CadFrameReplacer.MainForm')
$method=$type.GetMethod('ReadVerificationSummary',[Reflection.BindingFlags]'NonPublic,Static')
$summary=$method.Invoke($null,@([IO.Path]::GetFullPath($ReportPath)))
$reasons=$summary.FailureReasons
foreach($row in @($actual | Where-Object result -eq 'FAIL')) {
    if($reasons[[IO.Path]::GetFileName($row.file)] -ne $row.failure_reason) {
        throw 'Reason was lost while reading CSV in the application'
    }
}
# Older reports still supply accurate check names rather than an empty reason.
$legacy=$method.Invoke($null,@([IO.Path]::GetFullPath((Join-Path $LogsDirectory '最终验收报告.csv'))))
foreach($file in $legacy.FailedMainFileNames) {
    if([string]::IsNullOrWhiteSpace($legacy.FailureReasons[$file])) {throw 'Legacy fallback missing'}
}
'PASS: all original acceptance columns unchanged; every failed file has a reason; application CSV reader preserves complete reasons; legacy report fallback works.'
