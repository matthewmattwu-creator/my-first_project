param(
    [string]$InventoryDirectory = (Join-Path $PSScriptRoot 'inventory'),
    [string]$OutputCsv = (Join-Path $PSScriptRoot 'inventory\frame_inventory.csv')
)

$ErrorActionPreference = 'Stop'
$records = [System.Collections.Generic.List[object]]::new()
$rawRecords = [System.Collections.Generic.List[object]]::new()

function Add-InsertRecord {
    param(
        [string]$FileName,
        [pscustomobject]$Insert,
        [hashtable]$Attributes,
        [hashtable]$AttributeFlags
    )
    if ($null -eq $Insert) {
        return
    }
    $titleTags = @('建设单位', '设计项目名', '子项名称', '日期', '设计项目号', '图名', '图号', '图幅', '比例', '图别', '版本号')
    $matched = @($titleTags | Where-Object { $Attributes.ContainsKey($_) })
    $personnelNameTags = @(
        'N审定_T5_H3', 'N审核_T5_H3', 'N校对_T5_H3', 'N设计_T5_H3',
        'N专业负责人（副）二_T5_H3', 'N专业负责人（副）_T5_H3',
        'N专业负责人_T5_H3', 'N执行设总二_T5_H3',
        'N执行设总_T5_H3', 'N设计总负责人_T5_H3'
    )
    $visiblePersonnelTags = @($personnelNameTags | Where-Object {
        $Attributes.ContainsKey($_) -and
        -not [string]::IsNullOrWhiteSpace([string]$Attributes[$_]) -and
        (([int]$AttributeFlags[$_] -band 1) -eq 0)
    })
    $looksLikeFrame = (
        $Insert.block_name -like 'CFRSIG_*' -or
        $Insert.block_name -match '(^|[-_])TK([^-_]|[-_]|$)|图框|TITLE|FRAME' -or
        ($matched.Count -ge 3 -and $Attributes.ContainsKey('图号'))
    )
    $records.Add([pscustomobject]@{
        source_file = $FileName
        handle = $Insert.handle
        layout = $Insert.layout
        old_block = $Insert.block_name
        insertion_point = $Insert.insertion_point
        x_scale = $Insert.x_scale
        y_scale = $Insert.y_scale
        rotation = $Insert.rotation
        layer = $Insert.layer
        xref_path = $Insert.xref_path
        xref_resolved = $Insert.xref_resolved
        建设单位 = $Attributes['建设单位']
        设计项目名 = $Attributes['设计项目名']
        子项名称 = $Attributes['子项名称']
        日期 = $Attributes['日期']
        设计项目号 = $Attributes['设计项目号']
        图名 = $Attributes['图名']
        图号 = $Attributes['图号']
        图幅 = $Attributes['图幅']
        比例 = $Attributes['比例']
        图别 = $Attributes['图别']
        版本号 = $Attributes['版本号']
        单位 = $Attributes['单位']
        是否会签 = $Attributes['是否会签']
        图纸类别 = $Attributes['图纸类别']
        N审定_T5_H3 = $Attributes['N审定_T5_H3']
        N审核_T5_H3 = $Attributes['N审核_T5_H3']
        N校对_T5_H3 = $Attributes['N校对_T5_H3']
        N设计_T5_H3 = $Attributes['N设计_T5_H3']
        'N专业负责人（副）_T5_H3' = $Attributes['N专业负责人（副）_T5_H3']
        N专业负责人_T5_H3 = $Attributes['N专业负责人_T5_H3']
        N执行设总_T5_H3 = $Attributes['N执行设总_T5_H3']
        N设计总负责人_T5_H3 = $Attributes['N设计总负责人_T5_H3']
        N执行设总二_T5_H3 = $Attributes['N执行设总二_T5_H3']
        'N专业负责人（副）二_T5_H3' = $Attributes['N专业负责人（副）二_T5_H3']
        N设计总负责人_T6_H6 = $Attributes['N设计总负责人_T6_H6']
        N执行设总_T6_H6 = $Attributes['N执行设总_T6_H6']
        N执行设总二_T6_H6 = $Attributes['N执行设总二_T6_H6']
        N专业负责人_T6_H6 = $Attributes['N专业负责人_T6_H6']
        'N专业负责人（副）_T6_H8' = $Attributes['N专业负责人（副）_T6_H8']
        'N专业负责人（副）二_T6_H8' = $Attributes['N专业负责人（副）二_T6_H8']
        visible_personnel_tags = ($visiblePersonnelTags -join '|')
        N设计_T6_H6 = $Attributes['N设计_T6_H6']
        N校对_T6_H6 = $Attributes['N校对_T6_H6']
        N审核_T6_H6 = $Attributes['N审核_T6_H6']
        N审定_T6_H6 = $Attributes['N审定_T6_H6']
        matched_title_tags = ($matched -join '|')
        record_class = if ($matched.Count -ge 3 -and $Attributes.ContainsKey('图号')) {
            'TITLE'
        }
        elseif ($looksLikeFrame) {
            'FRAME_LIKE'
        }
        else {
            'OTHER_INSERT'
        }
    })
}

$files = @(Get-ChildItem -LiteralPath $InventoryDirectory -File -Filter '*.tsv' | Sort-Object Name)
foreach ($file in $files) {
    $rows = @(Import-Csv -Encoding UTF8 -Delimiter "`t" -LiteralPath $file.FullName)
    $drawingRow = $rows | Where-Object kind -eq 'DRAWING' | Select-Object -First 1
    $drawingName = if ($null -ne $drawingRow) { $drawingRow.block_name } else { $file.BaseName }
    $currentInsert = $null
    $attributes = @{}
    $attributeFlags = @{}

    foreach ($row in ($rows | Where-Object kind -eq 'ENTITY')) {
        switch ($row.entity_type) {
            'INSERT' {
                Add-InsertRecord -FileName $drawingName -Insert $currentInsert -Attributes $attributes -AttributeFlags $attributeFlags
                $currentInsert = $row
                $attributes = @{}
                $attributeFlags = @{}
            }
            'ATTRIB' {
                if ($null -ne $currentInsert -and -not [string]::IsNullOrWhiteSpace($row.tag)) {
                    $attributes[$row.tag] = $row.text
                    $attributeFlags[$row.tag] = if ([string]::IsNullOrWhiteSpace($row.flags)) { 0 } else { [int]$row.flags }
                }
            }
            'SEQEND' {
                Add-InsertRecord -FileName $drawingName -Insert $currentInsert -Attributes $attributes -AttributeFlags $attributeFlags
                $currentInsert = $null
                $attributes = @{}
                $attributeFlags = @{}
            }
            { $_ -in @('ACAD_PROXY_ENTITY', 'TEXT', 'MTEXT', 'ATTDEF', 'LINE') } {
                $rawRecords.Add([pscustomobject]@{
                    source_file = $drawingName
                    handle = $row.handle
                    layout = $row.layout
                    old_block = if ($row.entity_type -eq 'LINE') {
                        'LOOSE_LAYOUT_LINE'
                    }
                    else {
                        ''
                    }
                    insertion_point = $row.insertion_point
                    x_scale = if ($row.entity_type -eq 'LINE') { '1.00000000' } else { $row.x_scale }
                    y_scale = if ($row.entity_type -eq 'LINE') { '1.00000000' } else { $row.y_scale }
                    rotation = if ($row.entity_type -eq 'LINE') { '0.00000000' } else { $row.rotation }
                    layer = $row.layer
                    xref_path = ''
                    xref_resolved = ''
                    record_class = 'RAW_ENTITY'
                })
            }
        }
    }
    Add-InsertRecord -FileName $drawingName -Insert $currentInsert -Attributes $attributes -AttributeFlags $attributeFlags
}

foreach ($rawRecord in $rawRecords) {
    $records.Add($rawRecord)
}

$records | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
[pscustomobject]@{
    files = $files.Count
    records = $records.Count
    output = [IO.Path]::GetFullPath($OutputCsv)
}



