param(
    [Parameter(Mandatory = $true)]
    [string]$SourceInventoryCsv,

    [Parameter(Mandatory = $true)]
    [string]$OutputInventoryCsv,

    [Parameter(Mandatory = $true)]
    [string]$ReportCsv,

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

    [string]$SheetValuesPath = '',
    [string]$PlanDirectory = '',

    [ValidateSet('Replace', 'UpdateTitle')]
    [string]$OperationMode = 'Replace'
)

$ErrorActionPreference = 'Stop'
$preserveSentinel = '__CFR_PRESERVE__'
$clearSignatureSentinel = '__CFR_CLEAR_SIGNATURE__'
if ($建设单位 -eq $preserveSentinel) { $建设单位 = '' }
if ($设计项目名 -eq $preserveSentinel) { $设计项目名 = '' }
if ($出图日期 -eq $preserveSentinel) { $出图日期 = '' }
if ($设计项目号 -eq $preserveSentinel) { $设计项目号 = '' }

function Get-VisibleAttributeText {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }
    $marker = '\W0.8000;'
    $index = $Value.IndexOf($marker, [StringComparison]::Ordinal)
    if ($index -ge 0) {
        return $Value.Substring($index + $marker.Length)
    }
    return $Value
}

function Test-SuspiciousRequiredText {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }
    $visible = (Get-VisibleAttributeText $Value).Trim()
    if ([string]::IsNullOrWhiteSpace($visible)) {
        return $true
    }
    # Reject a dot and all other values consisting only of punctuation or
    # symbols.  At least one Unicode letter or number must remain visible.
    return $visible -notmatch '[\p{L}\p{N}\u4e00-\u9fff]'
}

function Get-GeometryKey {
    param($Row)
    return '{0}|{1}|{2}|{3}|{4}' -f
        ([string]$Row.layout).ToUpperInvariant(),
        $Row.insertion_point,
        $Row.x_scale,
        $Row.y_scale,
        $Row.rotation
}

function Test-SameList {
    param([object[]]$Left, [object[]]$Right)
    return @(Compare-Object @($Left) @($Right)).Count -eq 0
}

# Explain exact comparisons without changing the acceptance rule. Only pair
# transforms at an identical layout/point and with an unambiguous counterpart.
function Get-GeometryFailureDetails {
    param([object[]]$Expected, [object[]]$Actual, [string]$Label)
    foreach ($key in $Expected) {
        if ($Actual -contains $key) { continue }
        $parts = ([string]$key).Split('|')
        $matches = @($Actual | Where-Object {
            $candidate = ([string]$_).Split('|')
            $candidate[0] -eq $parts[0] -and $candidate[1] -eq $parts[1]
        })
        if ($matches.Count -ne 1) {
            "$Label 位置/布局或对应关系不一致：$key"
            continue
        }
        $other = ([string]$matches[0]).Split('|')
        foreach ($index in 2..4) {
            if ($parts[$index] -ne $other[$index]) {
                $field = @('', '', 'X缩放', 'Y缩放', '旋转(弧度)')[$index]
                "$Label $field 不一致：$($parts[$index]) → $($other[$index])（当前要求完全一致）"
            }
        }
    }
    if ($Expected.Count -ne $Actual.Count) {
        "$Label 几何记录数量不符：预期 $($Expected.Count)，实际 $($Actual.Count)"
    }
}

function Get-SourceFileName {
    param([string]$OutputFile)
    if ($OutputFile -match '_换框\.dwg$') {
        return $OutputFile -replace '_换框\.dwg$', '.dwg'
    }
    if ($OutputFile -match '_图签更新\.dwg$') {
        return $OutputFile -replace '_图签更新\.dwg$', '.dwg'
    }
    return $OutputFile
}

function Get-ExpectedRows {
    param(
        [object[]]$ConfiguredRows,
        [object[]]$PlanRows
    )
    if ($ConfiguredRows.Count -gt 0) {
        return @($ConfiguredRows)
    }
    return @($PlanRows)
}

function Test-FrameDependencyFileName {
    param([string]$FileName)
    $stem = [IO.Path]::GetFileNameWithoutExtension($FileName)
    return $stem -match '^(?i:A[012](?:\+(?:0\.)?\d+)?)$'
}

foreach ($required in @($SourceInventoryCsv, $OutputInventoryCsv)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Verification input not found: $required"
    }
}

$source = @(Import-Csv -LiteralPath $SourceInventoryCsv -Encoding UTF8)
$output = @(Import-Csv -LiteralPath $OutputInventoryCsv -Encoding UTF8)
if ($source.Count -eq 0) {
    throw "Source inventory is empty: $SourceInventoryCsv"
}
if ($output.Count -eq 0) {
    throw "Output inventory is empty: $OutputInventoryCsv"
}

$sheetValues = if (
    [string]::IsNullOrWhiteSpace($SheetValuesPath) -or
    -not (Test-Path -LiteralPath $SheetValuesPath -PathType Leaf)
) {
    @()
}
else {
    @(Import-Csv -LiteralPath $SheetValuesPath -Encoding UTF8 -Delimiter "`t")
}

$planRows = [Collections.Generic.List[object]]::new()
if (-not [string]::IsNullOrWhiteSpace($PlanDirectory) -and
    (Test-Path -LiteralPath $PlanDirectory -PathType Container)) {
    foreach ($planFile in @(
        Get-ChildItem -LiteralPath $PlanDirectory -File -Filter '*.tsv' |
            Sort-Object Name
    )) {
        foreach ($row in @(
            Import-Csv -LiteralPath $planFile.FullName -Encoding UTF8 -Delimiter "`t"
        )) {
            if ($row.status -in @('PLANNED', 'REPLACED', 'UPDATED')) {
                $planRows.Add($row)
            }
        }
    }
}
if ($planRows.Count -eq 0) {
    throw 'Verification plan is empty. Run the scan step again before Apply.'
}

$editableTags = @(
    '图号', '版本号', '图别', '设计项目号',
    'N审定_T5_H3', 'N审核_T5_H3', 'N校对_T5_H3', 'N设计_T5_H3',
    'N专业负责人（副）_T5_H3', 'N专业负责人_T5_H3',
    'N执行设总_T5_H3', 'N设计总负责人_T5_H3',
    '比例', '单位', '图名', '建设单位', '设计项目名', '子项名称',
    'N执行设总二_T5_H3',
    'N设计总负责人_T6_H6', 'N执行设总_T6_H6',
    'N执行设总二_T6_H6', 'N专业负责人_T6_H6',
    'N专业负责人（副）_T6_H8', 'N设计_T6_H6',
    'N校对_T6_H6', 'N审核_T6_H6', 'N审定_T6_H6',
    'N专业负责人（副）二_T5_H3', 'N专业负责人（副）二_T6_H8',
    '日期'
)
$multilineTags = @('建设单位', '设计项目名', '子项名称', '图名')
$signatureColumns = @(
    '签字图块_审定', '签字图块_审核', '签字图块_校对', '签字图块_设计',
    '签字图块_专业负责人副二', '签字图块_专业负责人副',
    '签字图块_专业负责人', '签字图块_执行设总二',
    '签字图块_执行设总', '签字图块_设计总负责人'
)
$personnelNameTags = @(
    'N审定_T5_H3', 'N审核_T5_H3', 'N校对_T5_H3', 'N设计_T5_H3',
    'N专业负责人（副）二_T5_H3', 'N专业负责人（副）_T5_H3',
    'N专业负责人_T5_H3', 'N执行设总二_T5_H3',
    'N执行设总_T5_H3', 'N设计总负责人_T5_H3'
)

$report = [Collections.Generic.List[object]]::new()
foreach ($outputGroup in ($output | Group-Object source_file | Sort-Object Name)) {
    $outputFile = $outputGroup.Name
    $sourceFile = Get-SourceFileName $outputFile
    $sourceRows = @($source | Where-Object source_file -eq $sourceFile)
    $filePlan = @($planRows | Where-Object drawing -eq $sourceFile)
    $titleOnlyPlan = @(
        $filePlan | Where-Object frame_spec -eq 'TITLE_ONLY'
    )
    $framePlan = @(
        $filePlan | Where-Object frame_spec -ne 'TITLE_ONLY'
    )
    # The field table can come from an earlier scan of the same session.  A
    # corrected planner may deliberately discard rows that were previously
    # false-positive detail captions.  Verify only configured rows that still
    # belong to the current plan; otherwise stale caption rows inflate the
    # expected field list and turn a correct replacement into a false FAIL.
    $plannedHandles = @(
        $filePlan |
            ForEach-Object old_frame_handle |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $configuredRows = @($sheetValues | Where-Object {
        $_.drawing -eq $sourceFile -and
        $plannedHandles -contains $_.old_frame_handle
    })
    $expectedRows = @(Get-ExpectedRows $configuredRows $filePlan)

    if ($filePlan.Count -eq 0 -and
        $configuredRows.Count -eq 0 -and
        (Test-FrameDependencyFileName -FileName $outputFile)) {
        $report.Add([pscustomobject]@{
            file = $outputFile
            mode = 'XrefDependencyCopy'
            planned_sheets = 0
            source_frames = 0
            source_titles = 0
            output_new_frames = 0
            output_new_titles = 0
            output_xref_overlays = 0
            selected_output_titles = 0
            structure_ok = $true
            unchanged_entities_ok = $true
            expected_signature_blocks = 0
            actual_signature_blocks = 0
            signature_blocks_ok = $true
            expected_preserved_signature_blocks = 0
            actual_preserved_signature_blocks = 0
            preserved_signature_blocks_ok = $true
            editable_fields_match = $true
            visible_personnel_ok = $true
            failure_reason = ''
            result = 'PASS'
        })
        continue
    }

    $frameHandles = @($framePlan | ForEach-Object old_frame_handle)
    $titleHandles = @(
        $filePlan |
            ForEach-Object old_title_handle |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $replaceTitleHandles = @(
        $framePlan |
            Where-Object virtual_title -ne '1' |
            ForEach-Object old_title_handle |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $titleOnlyHandles = @(
        $titleOnlyPlan |
            ForEach-Object old_title_handle |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $proxyTitleHandles = @(
        $filePlan | ForEach-Object {
            @(
                [string]$_.__proxy_drawing_name_handle
                [string]$_.__proxy_drawing_number_handle
            )
        } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $companionPaperHandles = @(
        $framePlan |
            ForEach-Object {
                @(([string]$_.companion_paper_handle) -split '\|')
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    $sourceFrames = @(
        $sourceRows | Where-Object { $frameHandles -contains $_.handle }
    )
    $sourceTitles = @(
        $sourceRows | Where-Object { $replaceTitleHandles -contains $_.handle }
    )
    $newFrames = @(
        $outputGroup.Group | Where-Object old_block -like 'NEW_FRAME_*'
    )
    $newTitles = @(
        $outputGroup.Group | Where-Object { $_.old_block -match '^NEW_TITLE(?:_CFR_[0-9]+)?$' }
    )
    $overlayTitles = @(
        $outputGroup.Group |
            Where-Object old_block -like 'CFR_XREF_TITLE_OVERLAY*'
    )
    $outputSelectedTitles = @(if ($OperationMode -eq 'UpdateTitle') {
        @(
            $outputGroup.Group |
                # A virtual XREF plan may carry a nearby detail-title handle
                # only as a conservative fallback source.  That detail block
                # is intentionally preserved and is not the editable main
                # title.  Select native title handles only for non-virtual
                # plans, plus the host-local XREF overlays below.
                Where-Object { $replaceTitleHandles -contains $_.handle }
            $overlayTitles
        )
    }
    else {
        @(
            $newTitles
            $outputGroup.Group |
                Where-Object { $titleOnlyHandles -contains $_.handle }
        )
    })

    $sourceSignatureBlocks = @(
        $sourceRows | Where-Object old_block -like 'CFRSIG_*'
    )
    $outputSignatureBlocks = @(
        $outputGroup.Group | Where-Object old_block -like 'CFRSIG_*'
    )
    $sourcePreservedSignatureBlocks = @(
        $sourceRows | Where-Object old_block -like 'CFRKEEP*'
    )
    $outputPreservedSignatureBlocks = @(
        $outputGroup.Group | Where-Object old_block -like 'CFRKEEP*'
    )
    $configuredSignatureCount = 0
    foreach ($configuredRow in $configuredRows) {
        foreach ($signatureColumn in $signatureColumns) {
            if (-not [string]::IsNullOrWhiteSpace(
                [string]$configuredRow.$signatureColumn
            ) -and
                [string]$configuredRow.$signatureColumn -ne
                    $clearSignatureSentinel) {
                $configuredSignatureCount++
            }
        }
    }
    $expectedSignatureCount =
        $sourceSignatureBlocks.Count + $configuredSignatureCount
    $plannedPreservedSignatureCount = (
        $filePlan |
            ForEach-Object {
                $count = 0
                [int]::TryParse(
                    [string]$_.preserved_signature_count,
                    [ref]$count
                ) | Out-Null
                $count
            } |
            Measure-Object -Sum
    ).Sum
    if ($null -eq $plannedPreservedSignatureCount) {
        $plannedPreservedSignatureCount = 0
    }
    $expectedPreservedSignatureCount = if ($OperationMode -eq 'Replace') {
        $sourcePreservedSignatureBlocks.Count +
            [int]$plannedPreservedSignatureCount
    }
    else {
        # UpdateTitle keeps the XREF itself, so its nested signatures remain
        # in place and must not be duplicated as CFRKEEP host blocks.
        $sourcePreservedSignatureBlocks.Count
    }

    $expectedFieldValuesMatch = $true
    $mismatchedFields = [Collections.Generic.List[string]]::new()
    foreach ($tag in $editableTags) {
        $compareVirtualOverlay =
            $OperationMode -eq 'UpdateTitle' -and
            $tag -in @('图名', '图号', '设计项目名', '设计项目号')
        $expectedTagRows = @($expectedRows | Where-Object {
            if ($OperationMode -ne 'UpdateTitle' -or $compareVirtualOverlay) {
                $true
            }
            else {
                $expectedHandle = [string]$_.old_frame_handle
                @(
                    $filePlan |
                        Where-Object {
                            $_.old_frame_handle -eq $expectedHandle -and
                            $_.virtual_title -eq '1'
                        }
                ).Count -eq 0
            }
        })
        $expectedValues = @(
            $expectedTagRows | ForEach-Object {
                $expectedValue = [string]($_.$tag)
                if ($tag.StartsWith('N', [StringComparison]::Ordinal)) {
                    if ($expectedValue -eq '[清空]') {
                        $expectedValue = ''
                    }
                    elseif ([string]::IsNullOrWhiteSpace($expectedValue)) {
                        $expectedHandle = [string]$_.old_frame_handle
                        $planMatch = @(
                            $filePlan |
                                Where-Object old_frame_handle -eq $expectedHandle |
                                Select-Object -First 1
                        )
                        if ($planMatch.Count -gt 0) {
                            $expectedValue = [string]($planMatch[0].$tag)
                        }
                    }
                }
                $expectedValue
            } | Sort-Object
        )
        $actualValues = @(
            @($outputSelectedTitles | Where-Object {
                $OperationMode -ne 'UpdateTitle' -or
                $compareVirtualOverlay -or
                $_.old_block -notlike 'CFR_XREF_TITLE_OVERLAY*'
            }) | ForEach-Object {
                $value = [string]($_.$tag)
                if ($multilineTags -contains $tag) {
                    Get-VisibleAttributeText $value
                }
                else {
                    $value
                }
            } | Sort-Object
        )
        if (-not (Test-SameList $expectedValues $actualValues)) {
            $expectedFieldValuesMatch = $false
            $mismatchedFields.Add($tag)
        }
    }

    # A personnel value stored in an invisible ATTRIB is not a successful
    # drawing update.  Require every explicitly supplied name to be visible
    # in the corresponding output title block.
    $visiblePersonnelOk = $true
    $missingVisiblePersonnel = [Collections.Generic.List[string]]::new()
    foreach ($tag in $personnelNameTags) {
        $expectedVisibleCount = @($configuredRows | Where-Object {
            $value = [string]($_.$tag)
            -not [string]::IsNullOrWhiteSpace($value) -and $value -ne '[清空]'
        }).Count
        $actualVisibleCount = @($outputSelectedTitles | Where-Object {
            @(([string]$_.visible_personnel_tags) -split '\|') -contains $tag
        }).Count
        if ($actualVisibleCount -lt $expectedVisibleCount) {
            $visiblePersonnelOk = $false
            $missingVisiblePersonnel.Add($tag)
        }
    }

    $sourceNonSignatureHandles = @(
        $sourceRows |
            Where-Object {
                $_.old_block -notlike 'CFRSIG_*' -and
                $_.old_block -notlike 'CFRKEEP*' -and
                $_.old_block -notlike 'CFR_XREF_TITLE_OVERLAY*' -and
                $proxyTitleHandles -notcontains $_.handle
            } |
            ForEach-Object handle |
            Sort-Object
    )
    $outputNonSignatureHandles = @(
        $outputGroup.Group |
            Where-Object {
                $_.old_block -notlike 'CFRSIG_*' -and
                $_.old_block -notlike 'CFRKEEP*' -and
                $_.old_block -notlike 'NEW_FRAME_*' -and
                $_.old_block -notmatch '^NEW_TITLE(?:_CFR_[0-9]+)?$'
            } |
            ForEach-Object handle |
            Sort-Object
    )
    if ($OperationMode -eq 'Replace') {
        $sourceNonSignatureHandles = @(
            $sourceRows |
                Where-Object {
                    $_.record_class -ne 'RAW_ENTITY' -and
                    $_.old_block -notlike 'CFRSIG_*' -and
                    $_.old_block -notlike 'CFRKEEP*' -and
                    $frameHandles -notcontains $_.handle -and
                    $replaceTitleHandles -notcontains $_.handle -and
                    $companionPaperHandles -notcontains $_.handle -and
                    $proxyTitleHandles -notcontains $_.handle
                } |
                ForEach-Object handle |
                Sort-Object
        )
        $outputNonSignatureHandles = @(
            $outputGroup.Group |
                Where-Object {
                    $_.record_class -ne 'RAW_ENTITY' -and
                    $_.old_block -notlike 'CFRSIG_*' -and
                    $_.old_block -notlike 'CFRKEEP*' -and
                    $_.old_block -notlike 'NEW_FRAME_*' -and
                    $_.old_block -notmatch '^NEW_TITLE(?:_CFR_[0-9]+)?$'
                } |
                ForEach-Object handle |
                Sort-Object
        )
    }
    else {
        $outputNonSignatureHandles = @(
            $outputGroup.Group |
                Where-Object {
                    $_.old_block -notlike 'CFRSIG_*' -and
                    $_.old_block -notlike 'CFRKEEP*' -and
                    $_.old_block -notlike 'CFR_XREF_TITLE_OVERLAY*' -and
                    $_.layer -ne 'CFR-XREF-TITLE-OVERLAY'
                } |
                ForEach-Object handle |
                Sort-Object
        )
    }

    $sourceFrameGeometry = @(
        @(
            $sourceFrames | Where-Object {
                $sourceHandle = [string]$_.handle
                @($framePlan | Where-Object {
                    $_.old_frame_handle -eq $sourceHandle -and
                    ($_.virtual_title -eq '1' -or
                     $_.old_frame_block -like 'LOOSE_LAYOUT_FRAME_*')
                }).Count -eq 0
            } | ForEach-Object { Get-GeometryKey $_ }
            $framePlan |
                Where-Object {
                    $_.virtual_title -eq '1' -or
                    $_.old_frame_block -like 'LOOSE_LAYOUT_FRAME_*'
                } |
                ForEach-Object {
                    '{0}|{1}|{2}|{3}|{4}' -f
                        ([string]$_.layout).ToUpperInvariant(),
                        $_.point,
                        $_.scale,
                        $_.y_scale,
                        $_.rotation
                }
        ) | Sort-Object
    )
    $sourceTitleGeometry = @(
        @(
            $looseLayoutTitleHandles = @(
                $framePlan |
                    Where-Object old_frame_block -like 'LOOSE_LAYOUT_FRAME_*' |
                    ForEach-Object old_title_handle
            )
            $sourceTitles |
                Where-Object { $looseLayoutTitleHandles -notcontains $_.handle } |
                ForEach-Object { Get-GeometryKey $_ }
            $framePlan |
                Where-Object old_frame_block -like 'LOOSE_LAYOUT_FRAME_*' |
                ForEach-Object {
                    '{0}|{1}|{2}|{3}|{4}' -f
                        ([string]$_.layout).ToUpperInvariant(),
                        $_.title_point,
                        $_.scale,
                        $_.y_scale,
                        $_.rotation
                }
            $filePlan |
                Where-Object virtual_title -eq '1' |
                ForEach-Object {
                    '{0}|{1}|{2}|{3}|{4}' -f
                        ([string]$_.layout).ToUpperInvariant(),
                        $_.title_point,
                        $_.scale,
                        $_.y_scale,
                        $_.rotation
                }
        ) | Sort-Object
    )
    $outputFrameGeometry = @(
        $newFrames | ForEach-Object { Get-GeometryKey $_ } | Sort-Object
    )
    $outputTitleGeometry = @(
        $newTitles | ForEach-Object { Get-GeometryKey $_ } | Sort-Object
    )

    $selectedFrameHandlesInOutput = @(
        $outputGroup.Group |
            Where-Object { $frameHandles -contains $_.handle }
    ).Count
    $selectedTitleHandlesInOutput = @(
        $outputGroup.Group |
            Where-Object { $replaceTitleHandles -contains $_.handle }
    ).Count
    $selectedTitleOnlyHandlesInOutput = @(
        $outputGroup.Group |
            Where-Object { $titleOnlyHandles -contains $_.handle }
    ).Count
    $remainingRecoveredOldTitleText = @(
        $outputGroup.Group |
            Where-Object { $proxyTitleHandles -contains $_.handle }
    ).Count
    $remainingCompanionPaper = @(
        $outputGroup.Group |
            Where-Object { $companionPaperHandles -contains $_.handle }
    ).Count
    $oldTitleTextRemovedOk =
        $remainingRecoveredOldTitleText -eq 0 -and
        $remainingCompanionPaper -eq 0
    # Verify the values that actually exist in the output DWG, rather than
    # trusting the pre-processing field table.  This catches writes that turn
    # a valid title into a dot or another punctuation-only value.
    $requiredFieldsOk = @(
        $outputSelectedTitles | Where-Object {
            (Test-SuspiciousRequiredText ([string]$_.图名)) -or
            (Test-SuspiciousRequiredText ([string]$_.图号))
        }
    ).Count -eq 0

    $structureOk = if ($OperationMode -eq 'Replace') {
        $newFrames.Count -eq $framePlan.Count -and
        $newTitles.Count -eq $framePlan.Count -and
        $selectedFrameHandlesInOutput -eq 0 -and
        $selectedTitleHandlesInOutput -eq 0 -and
        $selectedTitleOnlyHandlesInOutput -eq $titleOnlyPlan.Count -and
        (Test-SameList $sourceFrameGeometry $outputFrameGeometry) -and
        (Test-SameList $sourceTitleGeometry $outputTitleGeometry)
    }
    else {
        $virtualPlanCount = @(
            $filePlan | Where-Object virtual_title -eq '1'
        ).Count
        $localPlanCount = $filePlan.Count - $virtualPlanCount
        $selectedFrameHandlesInOutput -eq $filePlan.Count -and
        $selectedTitleHandlesInOutput -eq $localPlanCount -and
        $overlayTitles.Count -eq $virtualPlanCount
    }

    $unchangedEntitiesOk = Test-SameList `
        $sourceNonSignatureHandles `
        $outputNonSignatureHandles
    $signatureBlocksOk =
        $outputSignatureBlocks.Count -eq $expectedSignatureCount
    $preservedSignatureBlocksOk =
        $outputPreservedSignatureBlocks.Count -eq
            $expectedPreservedSignatureCount

    $reasons = [Collections.Generic.List[string]]::new()
    if (-not $structureOk) {
        $reasons.Add('图框/图签结构验收未通过')
        if ($OperationMode -eq 'Replace') {
            if ($newFrames.Count -ne $framePlan.Count -or $newTitles.Count -ne $framePlan.Count) {
                $reasons.Add("新图框/图签数量不符：预期各 $($framePlan.Count)，实际 $($newFrames.Count)/$($newTitles.Count)")
            }
            if ($selectedFrameHandlesInOutput -ne 0 -or $selectedTitleHandlesInOutput -ne 0 -or $selectedTitleOnlyHandlesInOutput -ne $titleOnlyPlan.Count) {
                $reasons.Add('原图框/图签的删除或保留数量不符')
            }
            foreach ($detail in @(Get-GeometryFailureDetails $sourceFrameGeometry $outputFrameGeometry '图框') + @(Get-GeometryFailureDetails $sourceTitleGeometry $outputTitleGeometry '图签')) {
                $reasons.Add($detail)
            }
        } else { $reasons.Add('保留图框/图签或外参覆盖图签数量不符') }
    }
    if (-not $unchangedEntitiesOk) { $reasons.Add('规划外实体句柄清单变化') }
    if (-not $signatureBlocksOk) { $reasons.Add("新签字块数量不符：预期 $expectedSignatureCount，实际 $($outputSignatureBlocks.Count)") }
    if (-not $preservedSignatureBlocksOk) { $reasons.Add('应保留签字块数量不符') }
    if (-not $expectedFieldValuesMatch) { $reasons.Add('字段写入结果不一致：' + ($mismatchedFields -join '、')) }
    if (-not $visiblePersonnelOk) { $reasons.Add('人员姓名未写入可见属性：' + ($missingVisiblePersonnel -join '、')) }
    if (-not $requiredFieldsOk) { $reasons.Add('图名或图号为空或仅含标点') }
    if (-not $oldTitleTextRemovedOk) { $reasons.Add('旧图签文字或配套底纸仍残留') }

    $report.Add([pscustomobject]@{
        file = $outputFile
        mode = $OperationMode
        planned_sheets = $filePlan.Count
        source_frames = $sourceFrames.Count
        source_titles = $sourceTitles.Count
        output_new_frames = $newFrames.Count
        output_new_titles = $newTitles.Count
        output_xref_overlays = $overlayTitles.Count
        selected_output_titles = $outputSelectedTitles.Count
        structure_ok = $structureOk
        unchanged_entities_ok = $unchangedEntitiesOk
        expected_signature_blocks = $expectedSignatureCount
        actual_signature_blocks = $outputSignatureBlocks.Count
        signature_blocks_ok = $signatureBlocksOk
        expected_preserved_signature_blocks =
            $expectedPreservedSignatureCount
        actual_preserved_signature_blocks =
            $outputPreservedSignatureBlocks.Count
        preserved_signature_blocks_ok = $preservedSignatureBlocksOk
        editable_fields_match = $expectedFieldValuesMatch
        visible_personnel_ok = $visiblePersonnelOk
        required_fields_ok = $requiredFieldsOk
        old_title_text_removed_ok = $oldTitleTextRemovedOk
        failure_reason = (@($reasons | Select-Object -Unique) -join '；')
        result = if (
            $structureOk -and
            $unchangedEntitiesOk -and
            $signatureBlocksOk -and
            $preservedSignatureBlocksOk -and
            $expectedFieldValuesMatch -and
            $visiblePersonnelOk -and
            $requiredFieldsOk -and
            $oldTitleTextRemovedOk
        ) {
            'PASS'
        }
        else {
            'FAIL'
        }
    })
}

$reportDirectory = Split-Path -Parent $ReportCsv
if (-not [string]::IsNullOrWhiteSpace($reportDirectory)) {
    New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
}
$report | Export-Csv -LiteralPath $ReportCsv -NoTypeInformation -Encoding UTF8
$failures = @($report | Where-Object result -ne 'PASS')

[pscustomobject]@{
    files = $report.Count
    frames = ($report | Measure-Object planned_sheets -Sum).Sum
    failed_files = $failures.Count
    report = [IO.Path]::GetFullPath($ReportCsv)
}

if ($failures.Count -gt 0) {
    $failures | Format-List *
    throw "CAD assistant verification failed for $($failures.Count) file(s)."
}
