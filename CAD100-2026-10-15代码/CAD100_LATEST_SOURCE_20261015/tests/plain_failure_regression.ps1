param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
$repo=Split-Path -Parent $PSScriptRoot
$assembly=[Reflection.Assembly]::LoadFrom((Join-Path $repo 'tmp/global-info-qa/application/CAD-100.exe'))
$type=$assembly.GetType('Drawing100WpfPreview.FailureExplanation')
$method=$type.GetMethod('FromTechnical')
function Check($condition,$label) {if(-not $condition){throw $label}; "PASS $label"}
$person='处理失败；字段写入结果不一致：N审定_T5_H3、N审核_T5_H3、N设计_T5_H3；人员姓名未写入可见属性：N审定_T5_H3、N审核_T5_H3、N设计_T5_H3'
$scale='处理失败；图框/图签结构验收未通过；图签 X缩放 不一致：150.00001811 → 150.00000000（当前要求完全一致）；图签 Y缩放 不一致：150.00001811 → 150.00000000（当前要求完全一致）'
$fields='处理失败；字段写入结果不一致：图名'
$cases=@($person,$scale,$fields,'处理失败；未知检查异常')
$all=@($cases | ForEach-Object {$method.Invoke($null,@([string]$_))})
Check ($all[0].Summary -eq '人员姓名未成功显示') 'personnel uses plain summary'
Check ($all[0].Reason.Contains('审定') -and $all[0].Reason.Contains('设计')) 'personnel identifies readable roles'
Check (-not ($all[0].Reason -match '_T\d+_H\d+')) 'personnel technical tags hidden from plain explanation'
$wrongName=$method.Invoke($null,@('处理失败；字段写入结果不一致：N设计_T5_H3'))
Check ($wrongName.Summary -eq '人员姓名与填写内容不一致') 'wrong name is not described as invisible'
Check ($all[1].Summary -eq '图签比例有细微差异') 'small scale classified without changing acceptance'
Check (-not $all[1].Reason.Contains('150.00001811')) 'precise values reserved for diagnostics'
$large=$method.Invoke($null,@('处理失败；图签 X缩放 不一致：1 → 2'))
Check ($large.Summary -eq '图签比例发生变化') 'large scale is not called tiny'
$mixed=$method.Invoke($null,@($person+'；'+$scale))
Check ($mixed.Summary.Contains('姓名') -and $mixed.Summary.Contains('比例')) 'multiple causes retained'
Check ($all[2].Reason.Contains('可能') -and $all[2].Reason.Contains('格式')) 'field mismatch does not assert a proven formatting cause'
Check ($all[3].Reason.Contains('不能')) 'unknown failure is not given an invented cause'
foreach($item in $all) {Check ($item.Advice.Length -gt 0 -and $item.Impact.Contains('尚未通过')) 'advice present; no automatic approval'}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$window=[Activator]::CreateInstance($assembly.GetType('Drawing100WpfPreview.MainWindow'))
$flags=[Reflection.BindingFlags]'NonPublic,Instance'
function Render($element,$width,$height,$file) {
    $element.Measure([Windows.Size]::new($width,$height))
    $element.Arrange([Windows.Rect]::new(0,0,$width,$height)); $element.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($width,$height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($element); $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $OutputDirectory $file))
    try {$encoder.Save($stream)} finally {$stream.Dispose()}
}
try {
    for($i=0;$i -lt 2;$i++) {
        $row=[Activator]::CreateInstance($assembly.GetType('Drawing100WpfPreview.DrawingRow'))
        $row.FullSourceFile=if($i -eq 0){'A1~C1栋墙身大样图_t8.dwg'}else{'A1~C1立剖面图_t8.dwg'}
        $row.Frame=if($i -eq 0){'1/1'}else{'1/5'}; $row.No=if($i -eq 0){'A-W-DT001'}else{'A-W-EL101'}; $row.Name=if($i -eq 0){'墙身大样图'}else{'1栋立面图'}
        $row.Tone='red'; $row.TechnicalResult=$cases[$i]; $row.Result='处理失败；'+$all[$i].Summary
        $dialog=$window.GetType().GetMethod('CreateResultDetailsWindow',$flags).Invoke($window,@($row))
        try {
            $root=$dialog.Content; $expander=$root.Children[1]
            Check ($root.RowDefinitions.Count -eq 3) 'detail layout has independent explanation, diagnostics and actions'
            Check (-not $expander.IsExpanded) 'diagnostics collapsed by default'
            Check ($expander.Content.Text -eq $cases[$i]) 'complete raw diagnostic retained'
            Check (-not $root.Children[0].Text.Contains('_T5_H3')) 'primary detail text is readable'
            Check ($root.Children[2].Children.Count -eq 3) 'copy explanation, copy diagnostic and close available'
            $previewName=if($i -eq 0){'CAD100人员问题直白说明.png'}else{'CAD100比例问题直白说明.png'}
            Render $root 788 570 $previewName
        } finally {$dialog.Close()}
    }
    $core=$window.GetType().GetField('core',$flags).GetValue($window); $table=$core.ShellTable
    for($i=0;$i -lt 4;$i++) {
        $r=$table.NewRow(); $r['drawing']='示例图纸'+($i+1)+'.dwg';$r['图号']='TEST-'+($i+1);$r['图名']='提示效果示例'
        $r['scan_status']=$cases[$i];$r['review_required']=$false;$r['review_confirmed']=$true;$table.Rows.Add($r)
    }
    $window.GetType().GetMethod('SyncFromCore',$flags).Invoke($window,@()) | Out-Null
    $grid=$window.GetType().GetField('drawingGrid',$flags).GetValue($window)
    $rows=@($grid.ItemsSource)
    Check ($rows.Count -eq 4 -and @($rows | Where-Object Tone -eq 'red').Count -eq 4) 'all four failures stay red'
    Check ($rows[0].Result.Contains('姓名未成功显示') -and $rows[0].TechnicalResult -eq $person) 'table summary changed; raw diagnostic preserved'
    Render $window.Content 1664 946 'CAD100直白失败提示界面.png'
} finally {$window.Close()}
'ALL PLAIN FAILURE CHECKS PASSED; no CAD processing, drawing writes or clipboard changes.'
