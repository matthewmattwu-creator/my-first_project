[CmdletBinding()]
param(
    [string]$Configuration = "Release",
    [string]$LicenseApiBaseUrl = "",
    [string]$LicensePublicKeyPath = "",
    [string]$AppVersion = "2.1.0"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$frameworkRoot = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
$compiler = Join-Path $frameworkRoot "csc.exe"

if (-not (Test-Path -LiteralPath $compiler)) {
    throw "The .NET Framework 64-bit C# compiler was not found: $compiler"
}
if ([string]::IsNullOrWhiteSpace($LicenseApiBaseUrl)) {
    Write-Warning "LicenseApiBaseUrl is empty. The app can only use an already cached offline license."
}
if ([string]::IsNullOrWhiteSpace($LicensePublicKeyPath) -or -not (Test-Path -LiteralPath $LicensePublicKeyPath)) {
    throw "A license RSA public key XML file is required."
}
if ($AppVersion -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
    throw "AppVersion must look like 2.1.0 or 2.1.0.1"
}

$outputRoot = Join-Path $repoRoot "dist\CAD-100"
$coreDll = Join-Path $outputRoot "CadProcessingCore.dll"
$appExe = Join-Path $outputRoot "CAD-100.exe"
$updaterExe = Join-Path $outputRoot "CAD100Updater.exe"
$tempRoot = Join-Path $repoRoot "tmp\license-build"
$utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$coreSourcePath = Join-Path $repoRoot "src\CadProcessingCore\Program.cs"
$coreTempPath = Join-Path $tempRoot "CadProcessingCore.Program.cs"
$coreSource = [IO.File]::ReadAllText($coreSourcePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
$scanNeedle = "private async Task ScanAsync()`n        {`n            if (busy || !ValidateInputs(false)) return;"
$scanReplacement = "private async Task ScanAsync()`n        {`n            CoreLicenseGuard.EnsureAuthorized(`"scan`");`n            if (busy || !ValidateInputs(false)) return;"
if (-not $coreSource.Contains($scanNeedle)) { throw "ScanAsync entry point changed; license injection could not be applied safely." }
$coreSource = $coreSource.Replace($scanNeedle, $scanReplacement)
$applyNeedle = "private async Task ApplyAsync()`n        {`n            if (busy || !ValidateInputs(true)) return;"
$applyReplacement = "private async Task ApplyAsync()`n        {`n            CoreLicenseGuard.EnsureAuthorized(`"apply`");`n            if (busy || !ValidateInputs(true)) return;"
if (-not $coreSource.Contains($applyNeedle)) { throw "ApplyAsync entry point changed; license injection could not be applied safely." }
$coreSource = $coreSource.Replace($applyNeedle, $applyReplacement)
[IO.File]::WriteAllText($coreTempPath, $coreSource, $utf8Bom)

$licenseGuardPath = Join-Path $repoRoot "src\CadProcessingCore\LicenseGuard.cs"
$licenseGuardTempPath = Join-Path $tempRoot "LicenseGuard.cs"
$licenseSource = [IO.File]::ReadAllText($licenseGuardPath, [Text.Encoding]::UTF8)
$publicKeyXml = [IO.File]::ReadAllText((Resolve-Path $LicensePublicKeyPath), [Text.Encoding]::UTF8).Trim()
$publicKeyBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKeyXml))
$licenseSource = $licenseSource.Replace("__CAD100_PUBLIC_KEY_XML_BASE64__", $publicKeyBase64)
$licenseSource = $licenseSource.Replace('public const string AppVersion = "2.0.0";', 'public const string AppVersion = "' + $AppVersion + '";')
[IO.File]::WriteAllText($licenseGuardTempPath, $licenseSource, $utf8Bom)

& $compiler /nologo /target:library /optimize+ /out:$coreDll /reference:System.dll /reference:System.Core.dll /reference:System.Configuration.dll /reference:System.Data.dll /reference:System.Drawing.dll /reference:System.Runtime.Serialization.dll /reference:System.Security.dll /reference:System.Windows.Forms.dll $coreTempPath $licenseGuardTempPath
if ($LASTEXITCODE -ne 0) { throw "CadProcessingCore compilation failed with exit code $LASTEXITCODE" }

function Find-GacAssembly([string]$relativeRoot, [string]$fileName) {
    $root = Join-Path $env:WINDIR "Microsoft.NET\assembly\$relativeRoot"
    $result = Get-ChildItem -LiteralPath $root -Recurse -Filter $fileName -ErrorAction Stop | Select-Object -First 1 -ExpandProperty FullName
    if (-not $result) { throw "Framework assembly was not found: $fileName" }
    return $result
}

$presentationFramework = Find-GacAssembly "GAC_MSIL\PresentationFramework" "PresentationFramework.dll"
$presentationCore = Find-GacAssembly "GAC_64\PresentationCore" "PresentationCore.dll"
$windowsBase = Find-GacAssembly "GAC_MSIL\WindowsBase" "WindowsBase.dll"
$systemXaml = Find-GacAssembly "GAC_MSIL\System.Xaml" "System.Xaml.dll"
$compression = Find-GacAssembly "GAC_MSIL\System.IO.Compression" "System.IO.Compression.dll"
$compressionFs = Find-GacAssembly "GAC_MSIL\System.IO.Compression.FileSystem" "System.IO.Compression.FileSystem.dll"

$wpfSourcePath = Join-Path $repoRoot "src\Drawing100Wpf\Program.cs"
$wpfTempPath = Join-Path $tempRoot "Drawing100Wpf.Program.cs"
$wpfSource = [IO.File]::ReadAllText($wpfSourcePath, [Text.Encoding]::UTF8)
$oldRun = "            app.Run(new MainWindow());"
$newRun = "            if (LicenseStartup.Authorize())`r`n            {`r`n                if (UpdateStartup.CheckAndMaybeUpdate()) app.Run(new MainWindow());`r`n                else app.Shutdown();`r`n            }`r`n            else app.Shutdown();"
if (-not $wpfSource.Contains($oldRun)) { throw "WPF startup point changed; startup injection could not be applied safely." }
$wpfSource = $wpfSource.Replace($oldRun, $newRun)
[IO.File]::WriteAllText($wpfTempPath, $wpfSource, $utf8Bom)

$updateSourcePath = Join-Path $repoRoot "src\Drawing100Wpf\UpdateManager.cs"
$updateTempPath = Join-Path $tempRoot "UpdateManager.cs"
$updateSource = [IO.File]::ReadAllText($updateSourcePath, [Text.Encoding]::UTF8).Replace("__CAD100_APP_VERSION__", $AppVersion)
[IO.File]::WriteAllText($updateTempPath, $updateSource, $utf8Bom)

& $compiler /nologo /target:winexe /optimize+ /out:$appExe /reference:System.dll /reference:System.Core.dll /reference:System.Configuration.dll /reference:System.Data.dll /reference:System.Drawing.dll /reference:System.Runtime.Serialization.dll /reference:System.Security.dll /reference:System.Windows.Forms.dll /reference:$presentationFramework /reference:$presentationCore /reference:$windowsBase /reference:$systemXaml /reference:$coreDll $wpfTempPath (Join-Path $repoRoot "src\Drawing100Wpf\LicenseWindow.cs") $updateTempPath
if ($LASTEXITCODE -ne 0) { throw "WPF application compilation failed with exit code $LASTEXITCODE" }

& $compiler /nologo /target:winexe /optimize+ /out:$updaterExe /reference:System.dll /reference:System.Core.dll /reference:$compression /reference:$compressionFs (Join-Path $repoRoot "src\CAD100Updater\Program.cs")
if ($LASTEXITCODE -ne 0) { throw "CAD100Updater compilation failed with exit code $LASTEXITCODE" }

$configSource = [IO.File]::ReadAllText((Join-Path $repoRoot "src\Drawing100Wpf\App.config"), [Text.Encoding]::UTF8)
$configSource = $configSource.Replace("__CAD100_LICENSE_API_BASE_URL__", $LicenseApiBaseUrl.TrimEnd('/'))
[IO.File]::WriteAllText(($appExe + ".config"), $configSource, $utf8Bom)

Copy-Item -LiteralPath (Join-Path $repoRoot "engine") -Destination $outputRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "templates") -Destination $outputRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "docs") -Destination $outputRoot -Recurse -Force

Write-Host "Build completed: $outputRoot"
Write-Host "Version: $AppVersion"
Write-Host "License/update API: $LicenseApiBaseUrl"
