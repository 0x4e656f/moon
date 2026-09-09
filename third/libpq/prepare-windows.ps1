<#
.SYNOPSIS
Deploy verified prebuilt libpq and dependencies; never compile libpq or run PostgreSQL/Moon.
.EXAMPLE
powershell -File third/libpq/prepare-windows.ps1 -Download
.EXAMPLE
powershell -File third/libpq/prepare-windows.ps1 -Archive C:/Downloads/postgresql-18.6-3-windows-x64-binaries.zip
#>
[CmdletBinding()]
param([string]$Archive, [switch]$Download, [switch]$Force)
$ErrorActionPreference = 'Stop'
$pqRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$pqManifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-runtime.json') -Raw | ConvertFrom-Json
$pqCache = Join-Path $pqRoot 'target/libpq-prebuilt'
$pqOutput = Join-Path $pqRoot 'clib/libpq'
New-Item -ItemType Directory -Path $pqCache, $pqOutput -Force | Out-Null
if (-not $Archive) { $Archive = Join-Path $pqCache $pqManifest.archive }
$Archive = [IO.Path]::GetFullPath($Archive)
if (-not (Test-Path -LiteralPath $Archive)) {
    if (-not $Download) { throw "Archive missing. Download from $($pqManifest.source_page), pass -Archive, or explicitly use -Download (about 344 MB)." }
    if ($Archive -ne (Join-Path $pqCache $pqManifest.archive)) { throw 'Automatic download only writes to the workspace cache.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $pqManifest.url -OutFile $Archive -UseBasicParsing
}
if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -ne $pqManifest.sha256) {
    throw 'Archive SHA256 mismatch. Nothing deployed; check the source/version before updating the manifest.'
}
if ((Get-Item -LiteralPath $pqOutput).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Output must not be a junction or symlink.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$pqStage = Join-Path $pqCache ('stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $pqStage | Out-Null
$pqZip = [IO.Compression.ZipFile]::OpenRead($Archive)
try {
    foreach ($pqName in @($pqManifest.dlls) + @($pqManifest.licenses)) {
        if ([IO.Path]::GetFileName($pqName) -ne $pqName) { throw 'Manifest entries must be filenames.' }
        $pqPrefix = if ($pqName.EndsWith('.dll')) { 'pgsql/bin/' } else { 'pgsql/' }
        $pqEntry = $pqZip.GetEntry($pqPrefix + $pqName)
        if (-not $pqEntry) { throw "Missing archive entry: $pqPrefix$pqName" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($pqEntry, (Join-Path $pqStage $pqName))
    }
} finally { $pqZip.Dispose() }

$pqChanges = @()
foreach ($pqSource in Get-ChildItem -LiteralPath $pqStage -File) {
    $pqTarget = Join-Path $pqOutput $pqSource.Name
    if (Test-Path -LiteralPath $pqTarget) {
        if ((Get-Item -LiteralPath $pqTarget).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing to overwrite a symlink.' }
        if ((Get-FileHash -LiteralPath $pqTarget).Hash -eq (Get-FileHash -LiteralPath $pqSource.FullName).Hash) { continue }
        if (-not $Force) { throw "Different existing file: $pqTarget. Stop Moon, then use -Force to back it up and replace it." }
    }
    $pqChanges += $pqSource
}
if ($pqChanges.Count -gt 0) {
    $pqBackup = Join-Path $pqStage 'previous'
    New-Item -ItemType Directory -Path $pqBackup | Out-Null
    foreach ($pqSource in $pqChanges) {
        $pqTarget = Join-Path $pqOutput $pqSource.Name
        if (Test-Path -LiteralPath $pqTarget) { Copy-Item -LiteralPath $pqTarget -Destination $pqBackup }
        Copy-Item -LiteralPath $pqSource.FullName -Destination $pqTarget -Force
    }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-runtime.json') -Destination (Join-Path $pqOutput 'runtime-manifest.json') -Force
Write-Output "Prebuilt libpq $($pqManifest.version) deployed to $pqOutput (6 DLLs plus licenses)."
Write-Output 'No PostgreSQL server, installer, pgAdmin or Moon executable was run.'
