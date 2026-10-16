$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $repoRoot 'tmp/global-info-qa'
$appRoot=Join-Path $testRoot 'application'
New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
Copy-Item -Path (Join-Path $repoRoot 'dist/CAD-100/*') -Destination $appRoot -Recurse -Force
$source=[IO.File]::ReadAllText((Join-Path $repoRoot 'tmp/license-build/CadProcessingCore.Program.cs'))
$rootLiteral='@"'+$testRoot.Replace('"','""')+'"'
$source=$source.Replace('Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)',$rootLiteral)
$testSource=Join-Path $testRoot 'CadProcessingCore.Test.cs'
[IO.File]::WriteAllText($testSource,$source,[Text.UTF8Encoding]::new($true))
$guard=(Resolve-Path (Join-Path $repoRoot 'tmp/license-build/LicenseGuard.cs')).Path
$compiler='C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $compiler /nologo /target:library /optimize+ "/out:$appRoot/CadProcessingCore.dll" /reference:System.dll /reference:System.Core.dll /reference:System.Configuration.dll /reference:System.Data.dll /reference:System.Drawing.dll /reference:System.Runtime.Serialization.dll /reference:System.Security.dll /reference:System.Windows.Forms.dll $testSource $guard
if($LASTEXITCODE -ne 0) {throw 'QA core compilation failed'}
$refs=@('PresentationFramework.dll','PresentationCore.dll','WindowsBase.dll','System.Xaml.dll') | ForEach-Object {
    '/reference:'+(Get-ChildItem -LiteralPath 'C:/Windows/Microsoft.NET/assembly' -Filter $_ -Recurse | Select-Object -First 1 -ExpandProperty FullName)
}
$testHarness=(Resolve-Path (Join-Path $PSScriptRoot 'global_info_regression.cs')).Path
$testExe=Join-Path $testRoot 'GlobalInfoRegression.exe'
& $compiler /nologo /target:exe "/out:$testExe" /reference:System.dll /reference:System.Core.dll /reference:System.Data.dll $refs $testHarness
if($LASTEXITCODE -ne 0) {throw 'QA harness compilation failed'}
& $testExe "$appRoot/CAD-100.exe" (Join-Path $testRoot 'folder-b') (Join-Path $testRoot 'global-info-preview.png') |
    Set-Content -LiteralPath (Join-Path $testRoot 'regression-results.txt') -Encoding utf8
if($LASTEXITCODE -ne 0) {throw 'Interaction regression failed'}
Get-Content (Join-Path $testRoot 'regression-results.txt') -Tail 5
