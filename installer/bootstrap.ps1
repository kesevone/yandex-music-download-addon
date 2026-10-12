$ErrorActionPreference = 'Stop'
$setupText = [IO.File]::ReadAllText($env:YM_ADDON_SETUP_FILE)
$payloadMatch = [regex]::Match($setupText, '(?ms)^:YM_PAYLOAD_BEGIN\r?\n(.*?)^:YM_PAYLOAD_END')
if (-not $payloadMatch.Success) { throw 'Installer payload is missing.' }
$archiveBytes = [Convert]::FromBase64String($payloadMatch.Groups[1].Value)
$sha = [Security.Cryptography.SHA256]::Create()
try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($archiveBytes)).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
function Get-PackageFileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}
if ($actualHash -ne '@@PAYLOAD_SHA256@@') { throw 'Installer checksum mismatch. Download the setup file again.' }
$action = $env:YM_ADDON_SETUP_ACTION
if ($action -and $action -notin @('--install', '--uninstall', '--check', '--extract-only')) { throw 'Use --install, --uninstall, --check, or --extract-only <empty directory>.' }
$extractOnly = $action -eq '--extract-only'
if ($extractOnly) {
    if (-not $env:YM_ADDON_SETUP_OUTPUT) { throw 'An extraction directory is required.' }
    $destination = [IO.Path]::GetFullPath($env:YM_ADDON_SETUP_OUTPUT)
    if (Test-Path -LiteralPath $destination) {
        if (-not (Test-Path -LiteralPath $destination -PathType Container) -or @(Get-ChildItem -LiteralPath $destination -Force).Count) { throw 'Extraction directory must be empty.' }
    }
} else { $destination = Join-Path ([IO.Path]::GetTempPath()) ('YandexMusicAddon-Setup-' + [Guid]::NewGuid().ToString('N')) }
try {
$allowedNames = @(@@ALLOWED_NAMES@@)
Add-Type -AssemblyName System.IO.Compression
$memory = New-Object IO.MemoryStream(,$archiveBytes)
$zip = New-Object IO.Compression.ZipArchive($memory, [IO.Compression.ZipArchiveMode]::Read)
try {
    if ($zip.Entries.Count -ne $allowedNames.Count) { throw 'Unexpected installer contents.' }
    $seen = @{}
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName -notin $allowedNames -or $seen.ContainsKey($entry.FullName) -or $entry.Length -gt 8MB) { throw 'Unexpected installer file.' }
        $seen[$entry.FullName] = $true
    }
    $manifestEntry = $zip.GetEntry('package.json')
    $reader = New-Object IO.StreamReader($manifestEntry.Open(), [Text.Encoding]::UTF8)
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    foreach ($entry in $zip.Entries) {
        $target = [IO.Path]::GetFullPath((Join-Path $destination $entry.FullName))
        if (-not $target.StartsWith($destination.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe archive path.' }
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $source = $entry.Open()
        $output = [IO.File]::Create($target)
        try { $source.CopyTo($output) } finally { $source.Dispose(); $output.Dispose() }
        if ($entry.FullName -ne 'package.json') {
            $expected = @($manifest.files | Where-Object { $_.path -eq $entry.FullName })
            if ($expected.Count -ne 1 -or (Get-PackageFileSha256 $target) -ne $expected[0].sha256) { throw 'Extracted file checksum mismatch.' }
        }
    }
} finally { $zip.Dispose(); $memory.Dispose() }
    if ($extractOnly) { Write-Host ('Verified files extracted to: ' + $destination); return }
    $installer = Join-Path $destination 'installer\install.ps1'
    switch ($action) {
        '--check' { & $installer -Action Check }
        '--install' { & $installer -Action Install }
        '--uninstall' { & $installer -Action Uninstall }
        default { & $installer -Action Menu }
    }
} finally {
    if (-not $extractOnly) {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ([IO.Path]::GetFullPath((Split-Path -Parent $destination)).TrimEnd('\') -ne $tempRoot -or (Split-Path -Leaf $destination) -notmatch '^YandexMusicAddon-Setup-[a-f0-9]{32}$') { throw 'Unsafe temporary cleanup path.' }
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    }
}
