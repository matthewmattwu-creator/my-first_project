param(
    [Parameter(Mandatory = $true)][string]$DxfPath,
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [string]$ReportPath = '',
    [string]$CandidateReportPath = ''
)

$ErrorActionPreference = 'Stop'
$invariant = [Globalization.CultureInfo]::InvariantCulture
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$drawingNumberColumn = ([string][char]0x56FE) + ([char]0x53F7)
$drawingNameColumn = ([string][char]0x56FE) + ([char]0x540D)

function Convert-HexBytes {
    param([Parameter(Mandatory = $true)][string]$Hex)
    $bytes = [byte[]]::new([int]($Hex.Length / 2))
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return $bytes
}

function Get-ProxyText {
    param([Collections.Generic.List[string]]$Chunks)
    if ($null -eq $Chunks -or $Chunks.Count -eq 0) { return '' }
    $hex = ($Chunks -join '')
    $marker = $hex.LastIndexOf('F401', [StringComparison]::OrdinalIgnoreCase)
    if ($marker -lt 0 -or $marker + 6 -gt $hex.Length) { return '' }
    $count = [Convert]::ToInt32($hex.Substring($marker + 4, 2), 16)
    $textStart = $marker + 6
    $textLength = $count * 4
    if ($count -le 0 -or $textStart + $textLength -gt $hex.Length) { return '' }
    $bytes = Convert-HexBytes -Hex $hex.Substring($textStart, $textLength)
    return ([Text.Encoding]::Unicode.GetString($bytes)).Trim([char]0, [char]0xFFFF, ' ')
}

function Get-ProxyGeometry {
    param([Collections.Generic.List[string]]$Chunks)
    $x = [double]::NaN
    $rotation = 0.0
    $hasRotation = $false
    if ($null -eq $Chunks) {
        return [pscustomobject]@{ X = $x; Y = [double]::NaN; Rotation = $rotation }
    }
    for ($chunkIndex = $Chunks.Count - 1; $chunkIndex -ge 0; $chunkIndex--) {
        $hex = $Chunks[$chunkIndex]
        if ($hex.Length -lt 24 -or -not $hex.StartsWith(
            '08600808', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $bytes = Convert-HexBytes -Hex $hex
        $x = [BitConverter]::ToDouble($bytes, 4)
        for ($offset = 12; $offset -le $bytes.Length - 8; $offset++) {
            $value = [BitConverter]::ToDouble($bytes, $offset)
            if (-not [double]::IsNaN($value) -and
                -not [double]::IsInfinity($value) -and
                [math]::Abs($value) -ge 0.05 -and
                [math]::Abs($value) -le 6.4) {
                $rotation = $value
                $hasRotation = $true
            }
        }
        break
    }
    if (-not $hasRotation) { $rotation = 0.0 }
    return [pscustomobject]@{ X = $x; Y = [double]::NaN; Rotation = $rotation }
}

function Convert-DxfRotationToRadians {
    param([double]$Rotation)
    # Ordinary DXF TEXT/MTEXT/ATTDEF group 50 is stored in degrees, while
    # AutoLISP plan rows use radians.  Proxy payloads observed in Tianzheng
    # may already be radians.  Values outside one full radian revolution are
    # therefore unambiguously degree values.
    if ([math]::Abs($Rotation) -gt (2.0 * [math]::PI + 0.001)) {
        return $Rotation * [math]::PI / 180.0
    }
    return $Rotation
}

function Test-DrawingNumber {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 80) { return $false }
    if ($Text -match '[\u3400-\u9fff]') { return $false }
    return (
        $Text -match '[A-Za-z]' -and
        $Text -match '\d' -and
        $Text -match '[-._~/]' -and
        $Text -match '^[A-Za-z0-9][A-Za-z0-9._~()/\-]*$'
    )
}

function Test-SuspiciousPlanDrawingNumber {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $value = $Text.Trim()
    # 1/2/9/A 这类一至两位标记通常是附近的剖面或详图编号，不能当图号。
    return $value -match '^[A-Za-z0-9]{1,2}$'
}

function Get-RotationDistance {
    param([double]$Left, [double]$Right)
    $twoPi = 2.0 * [math]::PI
    $difference = [math]::Abs($Left - $Right) % $twoPi
    return [math]::Min($difference, $twoPi - $difference)
}

function Parse-PointX {
    param([string]$Point)
    if ([string]::IsNullOrWhiteSpace($Point)) { return [double]::NaN }
    $fields = $Point.Split(',')
    if ($fields.Length -lt 2) { return [double]::NaN }
    return [double]::Parse($fields[0], $invariant)
}

function Parse-PointY {
    param([string]$Point)
    if ([string]::IsNullOrWhiteSpace($Point)) { return [double]::NaN }
    $fields = $Point.Split(',')
    if ($fields.Length -lt 2) { return [double]::NaN }
    return [double]::Parse($fields[1], $invariant)
}

function Get-WorldX {
    param(
        [double]$BaseX, [double]$LocalX, [double]$LocalY,
        [double]$ScaleX, [double]$ScaleY, [double]$Rotation
    )
    return $BaseX +
        ($LocalX * $ScaleX * [math]::Cos($Rotation)) -
        ($LocalY * $ScaleY * [math]::Sin($Rotation))
}


function Get-WorldY {
    param(
        [double]$BaseY, [double]$LocalX, [double]$LocalY,
        [double]$ScaleX, [double]$ScaleY, [double]$Rotation
    )
    return $BaseY +
        ($LocalX * $ScaleX * [math]::Sin($Rotation)) +
        ($LocalY * $ScaleY * [math]::Cos($Rotation))
}

if (-not (Test-Path -LiteralPath $DxfPath -PathType Leaf)) {
    throw "Proxy-title DXF not found: $DxfPath"
}
if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw "Frame plan not found: $PlanPath"
}

$layoutByOwner = @{}
$proxies = [Collections.Generic.List[object]]::new()
$entityType = ''
$handle = ''
$layer = ''
$owner = ''
$layoutNames = [Collections.Generic.List[string]]::new()
$layoutOwners = [Collections.Generic.List[string]]::new()
$chunks310 = [Collections.Generic.List[string]]::new()
$chunks311 = [Collections.Generic.List[string]]::new()
$textValue = ''
$attributeValue = ''
$pointX = [double]::NaN
$pointY = [double]::NaN
$textRotation = 0.0
$entityOrder = 0

function Complete-DxfEntity {
    if ($script:entityType -eq 'LAYOUT') {
        if ($script:layoutNames.Count -gt 0 -and $script:layoutOwners.Count -gt 0) {
            $script:layoutByOwner[$script:layoutOwners[$script:layoutOwners.Count - 1]] =
                $script:layoutNames[$script:layoutNames.Count - 1]
        }
    }
    elseif ($script:entityType -eq 'ACAD_PROXY_ENTITY') {
        $text = Get-ProxyText -Chunks $script:chunks311
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $geometry = Get-ProxyGeometry -Chunks $script:chunks310
            if (-not [double]::IsNaN($geometry.X)) {
                $script:proxies.Add([pscustomobject]@{
                    Type = $script:entityType
                    Handle = $script:handle
                    Owner = $script:owner
                    Layer = $script:layer
                    Text = $text
                    X = [double]$geometry.X
                    Y = [double]$geometry.Y
                    Rotation = [double]$geometry.Rotation
                    Order = $script:entityOrder
                })
            }
        }
    }
    elseif ($script:entityType -in @('TEXT', 'MTEXT', 'ATTRIB', 'ATTDEF')) {
        $text = if ($script:entityType -eq 'ATTDEF' -and
            -not [string]::IsNullOrWhiteSpace($script:attributeValue)) {
            $script:attributeValue
        } else {
            $script:textValue
        }
        if (-not [string]::IsNullOrWhiteSpace($text) -and
            -not [double]::IsNaN($script:pointX)) {
            $script:proxies.Add([pscustomobject]@{
                Type = $script:entityType
                Handle = $script:handle
                Owner = $script:owner
                Layer = $script:layer
                Text = $text.Trim()
                X = [double]$script:pointX
                Y = [double]$script:pointY
                Rotation = Convert-DxfRotationToRadians `
                    -Rotation ([double]$script:textRotation)
                Order = $script:entityOrder
            })
        }
    }
}

$reader = [IO.StreamReader]::new($DxfPath, [Text.Encoding]::UTF8, $true)
try {
    while (-not $reader.EndOfStream) {
        $groupLine = $reader.ReadLine()
        if ($reader.EndOfStream) { break }
        $value = $reader.ReadLine().Trim()
        $group = 0
        if (-not [int]::TryParse($groupLine.Trim(), [ref]$group)) { continue }
        if ($group -eq 0) {
            Complete-DxfEntity
            $entityType = $value
            $handle = ''
            $layer = ''
            $owner = ''
            $layoutNames = [Collections.Generic.List[string]]::new()
            $layoutOwners = [Collections.Generic.List[string]]::new()
            $chunks310 = [Collections.Generic.List[string]]::new()
            $chunks311 = [Collections.Generic.List[string]]::new()
            $textValue = ''
            $attributeValue = ''
            $pointX = [double]::NaN
            $pointY = [double]::NaN
            $textRotation = 0.0
            $entityOrder++
            continue
        }
        switch ($group) {
            1 {
                if ($entityType -eq 'LAYOUT') { $layoutNames.Add($value) }
                elseif ($entityType -in @('TEXT', 'MTEXT', 'ATTRIB', 'ATTDEF')) {
                    $textValue = $value
                }
            }
            2 {
                if ($entityType -eq 'ATTDEF') { $attributeValue = $value }
            }
            5 { $handle = $value }
            8 { $layer = $value }
            10 {
                if ($entityType -in @('TEXT', 'MTEXT', 'ATTRIB', 'ATTDEF')) {
                    $parsedX = 0.0
                    if ([double]::TryParse($value, [Globalization.NumberStyles]::Float,
                        $invariant, [ref]$parsedX)) { $pointX = $parsedX }
                }
            }
            20 {
                if ($entityType -in @('TEXT', 'MTEXT', 'ATTRIB', 'ATTDEF')) {
                    $parsedY = 0.0
                    if ([double]::TryParse($value, [Globalization.NumberStyles]::Float,
                        $invariant, [ref]$parsedY)) { $pointY = $parsedY }
                }
            }
            50 {
                if ($entityType -in @('TEXT', 'MTEXT', 'ATTRIB', 'ATTDEF')) {
                    $parsedRotation = 0.0
                    if ([double]::TryParse($value, [Globalization.NumberStyles]::Float,
                        $invariant, [ref]$parsedRotation)) { $textRotation = $parsedRotation }
                }
            }
            310 { if ($entityType -eq 'ACAD_PROXY_ENTITY') { $chunks310.Add($value) } }
            311 { if ($entityType -eq 'ACAD_PROXY_ENTITY') { $chunks311.Add($value) } }
            330 {
                $owner = $value
                if ($entityType -eq 'LAYOUT') { $layoutOwners.Add($value) }
            }
        }
    }
    Complete-DxfEntity
}
finally {
    $reader.Dispose()
}

foreach ($proxy in $proxies) {
    $proxy | Add-Member -NotePropertyName Layout -NotePropertyValue $(
        if ($layoutByOwner.ContainsKey($proxy.Owner)) { $layoutByOwner[$proxy.Owner] } else { '' }
    )
    $proxy | Add-Member -NotePropertyName IsNumber -NotePropertyValue $(
        Test-DrawingNumber -Text $proxy.Text
    )
}

if (-not [string]::IsNullOrWhiteSpace($CandidateReportPath)) {
    $proxies |
        Select-Object Type, Handle, Owner, Layout, Layer, Text, X, Y, Rotation, Order, IsNumber |
        Export-Csv -LiteralPath $CandidateReportPath -NoTypeInformation -Encoding UTF8
}

$rows = @(Import-Csv -LiteralPath $PlanPath -Encoding UTF8 -Delimiter "`t")
$frames = [Collections.Generic.List[object]]::new()
for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
    $row = $rows[$rowIndex]
    if ($row.status -notin @('PLANNED', 'REQUIRES_REPLACE')) { continue }
    $numberText = [string]$row.PSObject.Properties[$drawingNumberColumn].Value
    $nameText = [string]$row.PSObject.Properties[$drawingNameColumn].Value
    $needsRecovery = [string]::IsNullOrWhiteSpace($numberText) -or
        [string]::IsNullOrWhiteSpace($nameText) -or
        ($numberText.Trim() -match '^[A-Za-z0-9]{1,2}$')
    if (-not $needsRecovery) { continue }
    $baseX = Parse-PointX -Point $row.title_point
    $baseY = Parse-PointY -Point $row.title_point
    if ([double]::IsNaN($baseX) -or [double]::IsNaN($baseY)) { continue }
    $scaleX = if ([string]::IsNullOrWhiteSpace($row.scale)) { 1.0 } else {
        [double]::Parse($row.scale, $invariant)
    }
    $scaleY = if ([string]::IsNullOrWhiteSpace($row.y_scale)) { $scaleX } else {
        [double]::Parse($row.y_scale, $invariant)
    }
    $rotation = if ([string]::IsNullOrWhiteSpace($row.rotation)) { 0.0 } else {
        [double]::Parse($row.rotation, $invariant)
    }
    $frames.Add([pscustomobject]@{
        RowIndex = $rowIndex
        Row = $row
        Layout = [string]$row.layout
        ScaleX = $scaleX
        ScaleY = $scaleY
        Rotation = $rotation
        NumberX = Get-WorldX -BaseX $baseX -LocalX (-9.9184) -LocalY 12.0759 `
            -ScaleX $scaleX -ScaleY $scaleY -Rotation $rotation
        NumberY = Get-WorldY -BaseY $baseY -LocalX (-9.9184) -LocalY 12.0759 `
            -ScaleX $scaleX -ScaleY $scaleY -Rotation $rotation
        NameX = Get-WorldX -BaseX $baseX -LocalX (-35.0) -LocalY 118.157 `
            -ScaleX $scaleX -ScaleY $scaleY -Rotation $rotation
        NameY = Get-WorldY -BaseY $baseY -LocalX (-35.0) -LocalY 118.157 `
            -ScaleX $scaleX -ScaleY $scaleY -Rotation $rotation
    })
}

$numberCandidates = @($proxies | Where-Object IsNumber)
$matches = [Collections.Generic.List[object]]::new()
foreach ($frame in $frames) {
    foreach ($candidate in $numberCandidates) {
        if (-not [string]::Equals(
            $frame.Layout, $candidate.Layout, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rotationError = Get-RotationDistance -Left $frame.Rotation -Right $candidate.Rotation
        if ($rotationError -gt 0.08) { continue }
        $xError = [math]::Abs($frame.NumberX - $candidate.X)
        $yError = if ([double]::IsNaN($candidate.Y)) { 0.0 } else {
            [math]::Abs($frame.NumberY - $candidate.Y)
        }
        # Some resolved XREF title graphics are shifted horizontally from the
        # nested frame anchor by roughly 200 drawing units, while their sheet
        # rows remain exact on the perpendicular axis.  Permit that known
        # horizontal offset, but keep a tight Y/rotation/layout gate and later
        # require an adjacent name candidate so unrelated drawing annotation
        # cannot be selected.
        $xLimit = [math]::Max(250.0, 250.0 * [math]::Abs($frame.ScaleX))
        $yLimit = [math]::Max(30.0, 30.0 * [math]::Abs($frame.ScaleY))
        if ($xError -gt $xLimit -or $yError -gt $yLimit) { continue }
        $sourceNameEvidence = $false
        $sourceName = [string]$frame.Row.old_drawing_name
        if (-not [string]::IsNullOrWhiteSpace($sourceName)) {
            foreach ($possibleName in $proxies) {
                if ($possibleName.IsNumber -or
                    -not [string]::Equals(
                        $frame.Layout, $possibleName.Layout,
                        [StringComparison]::OrdinalIgnoreCase) -or
                    -not [string]::Equals(
                        $sourceName.Trim(), ([string]$possibleName.Text).Trim(),
                        [StringComparison]::OrdinalIgnoreCase)) { continue }
                $nameRotationError = Get-RotationDistance `
                    -Left $frame.Rotation -Right $possibleName.Rotation
                $nameOrderDistance = [math]::Abs(
                    [int]$possibleName.Order - [int]$candidate.Order)
                if ($nameRotationError -le 0.08 -and $nameOrderDistance -le 2) {
                    $sourceNameEvidence = $true
                    break
                }
            }
        }
        $sourceNumberEvidence = (
            -not [string]::IsNullOrWhiteSpace([string]$frame.Row.old_drawing_number) -and
            [string]::Equals(
                ([string]$frame.Row.old_drawing_number).Trim(),
                ([string]$candidate.Text).Trim(),
                [StringComparison]::OrdinalIgnoreCase)
        )
        $matches.Add([pscustomobject]@{
            Frame = $frame
            Candidate = $candidate
            Score = $xError + $yError + (100.0 * $rotationError) -
                $(if ($sourceNameEvidence) { 10000.0 } else { 0.0 }) -
                $(if ($sourceNumberEvidence) { 10000.0 } else { 0.0 })
        })
    }
}

$usedRows = [Collections.Generic.HashSet[int]]::new()
$usedNumberHandles = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
$usedNameHandles = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase)
$recoveries = [Collections.Generic.List[object]]::new()

foreach ($match in @($matches | Sort-Object Score)) {
    $frame = $match.Frame
    $number = $match.Candidate
    if ($usedRows.Contains([int]$frame.RowIndex) -or
        $usedNumberHandles.Contains([string]$number.Handle)) { continue }
    [void]$usedRows.Add([int]$frame.RowIndex)
    [void]$usedNumberHandles.Add([string]$number.Handle)

    $name = $null
    $nameScore = [double]::PositiveInfinity
    foreach ($candidate in $proxies) {
        if ($candidate.IsNumber -or
            $usedNameHandles.Contains([string]$candidate.Handle) -or
            -not [string]::Equals(
                $frame.Layout, $candidate.Layout, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rotationError = Get-RotationDistance -Left $frame.Rotation -Right $candidate.Rotation
        if ($rotationError -gt 0.08) { continue }
        $xError = [math]::Abs($frame.NameX - $candidate.X)
        $yError = if ([double]::IsNaN($candidate.Y)) { 0.0 } else {
            [math]::Abs($frame.NameY - $candidate.Y)
        }
        if ($xError -gt [math]::Max(250.0, 250.0 * [math]::Abs($frame.ScaleX)) -or
            $yError -gt [math]::Max(45.0, 45.0 * [math]::Abs($frame.ScaleY))) { continue }
        $orderDistance = [math]::Abs([int]$candidate.Order - [int]$number.Order)
        $score = $xError + $yError + (10.0 * [math]::Abs($orderDistance - 1)) +
            (100.0 * $rotationError)
        if ($score -lt $nameScore) {
            $name = $candidate
            $nameScore = $score
        }
    }

    # A number by itself is not enough when using the wider local-X window.
    # The intended title is authored immediately before/after it in the DXF
    # stream and must also satisfy the expected name-row geometry.
    if ($null -eq $name) { continue }

    $row = $frame.Row
    if ($null -eq $row.PSObject.Properties['__proxy_drawing_number_handle']) {
        $row | Add-Member -NotePropertyName '__proxy_drawing_number_handle' -NotePropertyValue ''
    }
    if ($null -eq $row.PSObject.Properties['__proxy_drawing_name_handle']) {
        $row | Add-Member -NotePropertyName '__proxy_drawing_name_handle' -NotePropertyValue ''
    }
    $row.$drawingNumberColumn = $number.Text
    $row.__proxy_drawing_number_handle = $number.Handle
    if ($null -ne $name) {
        $row.$drawingNameColumn = $name.Text
        $row.__proxy_drawing_name_handle = $name.Handle
        [void]$usedNameHandles.Add([string]$name.Handle)
    }
    $recoveries.Add([pscustomobject]@{
        drawing = $row.drawing
        layout = $row.layout
        old_frame_handle = $row.old_frame_handle
        drawing_number = $number.Text
        drawing_number_handle = $number.Handle
        drawing_name = if ($null -ne $name) { $name.Text } else { '' }
        drawing_name_handle = if ($null -ne $name) { $name.Handle } else { '' }
        number_x_error = [math]::Round([math]::Abs($frame.NumberX - $number.X), 4)
        name_x_error = if ($null -ne $name) {
            [math]::Round([math]::Abs($frame.NameX - $name.X), 4)
        } else { '' }
    })
}

$headers = [Collections.Generic.List[string]]::new()
foreach ($property in $rows[0].PSObject.Properties.Name) { $headers.Add($property) }
foreach ($column in @('__proxy_drawing_name_handle', '__proxy_drawing_number_handle')) {
    if (-not $headers.Contains($column)) { $headers.Add($column) }
    foreach ($row in $rows) {
        if ($null -eq $row.PSObject.Properties[$column]) {
            $row | Add-Member -NotePropertyName $column -NotePropertyValue ''
        }
    }
}
function Clean-TsvValue([object]$Value) {
    return ([string]$Value).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')
}
$outputLines = [Collections.Generic.List[string]]::new()
$outputLines.Add(($headers -join "`t"))
foreach ($row in $rows) {
    $fields = foreach ($header in $headers) { Clean-TsvValue $row.$header }
    $outputLines.Add(($fields -join "`t"))
}
[IO.File]::WriteAllLines($PlanPath, $outputLines.ToArray(), $utf8NoBom)

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = $PlanPath + '.proxy_title_recovery.csv'
}
$recoveries | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
Write-Host ("Recovered proxy title fields: {0}/{1} virtual frames ({2})" -f
    $recoveries.Count, $frames.Count, [IO.Path]::GetFileName($PlanPath))
