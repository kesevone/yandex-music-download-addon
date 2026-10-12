param(
    [ValidateSet('Menu', 'Install', 'Uninstall', 'Check')][string]$Action = 'Menu',
    [switch]$DryRun,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'YandexMusicDownloadAddon'),
    [string]$AppExe = '',
    [string]$NodeExe = '',
    [string]$PythonExe = '',
    [string]$FFmpegExe = '',
    [string[]]$ShortcutDirectories = @(),
    [string]$DependencyArchiveDirectory = '',
    [switch]$ForcePortable
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src'))
$sources = @('ym-button-helper.mjs', 'ym-download-button.js', 'ym-download-queue.js', 'ym-active-track.js', 'yandex_music.py', 'yandex_music_button.py', 'ym-session-export.mjs', 'launch_music_installed.ps1', 'launch_music_hidden.vbs', 'uninstall_music_autoload.ps1', 'ym-shortcuts.ps1')
$startupFiles = @('launch_music_hidden.vbs', 'launch_music_installed.ps1', 'uninstall_music_autoload.ps1', 'ym-shortcuts.ps1')
$rootFiles = @('LICENSE', 'THIRD_PARTY_NOTICES.md')
$configPath = Join-Path $InstallRoot 'config.json'
$manifestPath = Join-Path $PSScriptRoot 'dependencies.json'
$script:Step = 0

function Write-Step([string]$Text) {
    $script:Step++
    Write-Host ("`n [{0}/5] {1}" -f $script:Step, $Text) -ForegroundColor Yellow
}

function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $stream.Dispose(); $sha.Dispose() }
}

function Get-CanonicalAppPath([string]$Path) {
    if (-not ('YandexMusicAddon.InstallerPaths' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
namespace YandexMusicAddon {
    public static class InstallerPaths {
        [DllImport("kernel32.dll", EntryPoint="GetLongPathNameW", ExactSpelling=true,
                   CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetLongPathName(string path, StringBuilder value, uint count);
        public static string Canonicalize(string path) {
            string full = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path));
            var value = new StringBuilder(32768);
            uint length = GetLongPathName(full, value, (uint)value.Capacity);
            if (length == 0) { return full; }
            if (length >= value.Capacity) {
                value = new StringBuilder(checked((int)length + 1));
                length = GetLongPathName(full, value, (uint)value.Capacity);
                if (length == 0 || length >= value.Capacity) { return full; }
            }
            return value.ToString();
        }
    }
}
'@
    }
    [YandexMusicAddon.InstallerPaths]::Canonicalize($Path)
}

function Invoke-Probe([string]$Executable, [string]$Arguments) {
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf) -or $Executable -match '\\Microsoft\\WindowsApps\\') { return $null }
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = $Arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        if (-not $process.Start()) { return $null }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); return $null }
        $text = $output.GetAwaiter().GetResult() + $errors.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0) { return $text.Trim() }
    } catch { return $null } finally { $process.Dispose() }
}

function Test-Runtime([string]$Kind, [string]$Executable) {
    switch ($Kind) {
        'node' { $version = Invoke-Probe $Executable '--version'; return ($version -match '^v(\d+)\.' -and [int]$Matches[1] -ge 22) }
        'python' { $version = Invoke-Probe $Executable '-c "import sys; print(\"%d.%d\" % sys.version_info[:2])"'; return ($version -match '^3\.(\d+)$' -and [int]$Matches[1] -ge 12) }
        'ffmpeg' { $version = Invoke-Probe $Executable '-version'; return ($version -match '^ffmpeg version (\d+)\.' -and [int]$Matches[1] -ge 6) }
    }
    return $false
}

function Find-Runtime([string]$Kind, [string]$ExplicitPath, $OldConfig, $Dependency) {
    if ($ExplicitPath) {
        $candidate = [IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Runtime $Kind $candidate)) { throw "Incompatible explicit $Kind executable: $candidate" }
        return $candidate
    }
    if ($ForcePortable) { return $null }
    $candidates = @()
    if ($OldConfig) { $property = $Kind + 'Exe'; $candidates += $OldConfig.$property }
    $candidates += Join-Path $InstallRoot ('deps\' + $Dependency.directory + '\' + $Dependency.executable)
    $commands = @(Get-Command ($Kind + '.exe') -CommandType Application -All -ErrorAction SilentlyContinue)
    $candidates += @($commands | ForEach-Object { $_.Source })
    if ($Kind -eq 'node') { $candidates += Join-Path $env:ProgramFiles 'nodejs\node.exe' }
    if ($Kind -eq 'python') {
        foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), $env:ProgramFiles)) {
            if (Test-Path -LiteralPath $base) { $candidates += @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'python.exe' }) }
        }
    }
    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Runtime $Kind $candidate) { return [IO.Path]::GetFullPath($candidate) }
    }
    return $null
}

function Assert-SafeZipEntry($Entry, [string]$Root) {
    $name = $Entry.FullName.Replace('\', '/')
    if (-not $name -or $name.StartsWith('/') -or $name.Contains(':') -or $name -match '(^|/)\.\.(/|$)' -or (($Entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe dependency archive path.' }
    $target = [IO.Path]::GetFullPath((Join-Path $Root $name))
    if (-not $target.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe dependency archive path.' }
}

function Expand-Dependency([string]$Archive, [string]$Destination, $Dependency) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $total = 0L
        if ($zip.Entries.Count -gt 20000) { throw 'Dependency archive contains too many files.' }
        $seen = @{}
        foreach ($entry in $zip.Entries) {
            Assert-SafeZipEntry $entry $Destination
            $total += $entry.Length
            if ($total -gt 1GB) { throw 'Dependency archive is unexpectedly large.' }
            if (-not $entry.FullName.StartsWith([string]$Dependency.prefix, [StringComparison]::Ordinal)) { continue }
            $relative = $entry.FullName.Substring($Dependency.prefix.Length)
            if (-not $relative -or $relative.EndsWith('/')) { continue }
            if ($Dependency.files.Count -and $relative -notin $Dependency.files) { continue }
            if ($seen.ContainsKey($relative.ToLowerInvariant())) { throw 'Duplicate dependency archive file.' }
            $seen[$relative.ToLowerInvariant()] = $true
            $target = Join-Path $Destination $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $Dependency.executable) -PathType Leaf)) { throw 'Expected dependency executable is missing.' }
    } finally { $zip.Dispose() }
}

function Get-Dependency([string]$Kind, $Dependency) {
    $destination = Join-Path $InstallRoot ('deps\' + $Dependency.directory)
    $archive = Join-Path $InstallRoot ('cache\' + $Dependency.directory + '.zip')
    if ($DryRun) { Write-Host ('     Would download portable ' + $Kind + ' ' + $Dependency.version); return Join-Path $destination $Dependency.executable }
    if ($DependencyArchiveDirectory) {
        $archive = Join-Path $DependencyArchiveDirectory ([IO.Path]::GetFileName(([uri]$Dependency.url).AbsolutePath))
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'Fixture dependency archive is missing.' }
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $archive) | Out-Null
        if ((Test-Path -LiteralPath $archive) -and (Get-FileSha256 $archive) -ne $Dependency.sha256) { Remove-Item -LiteralPath $archive -Force }
        if (-not (Test-Path -LiteralPath $archive)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $client = New-Object Net.WebClient
            $part = $archive + '.part'
            $timer = [Diagnostics.Stopwatch]::StartNew()
            try {
                $task = $client.DownloadFileTaskAsync([uri]$Dependency.url, $part)
                $frames = @('|', '/', '-', '\')
                $frame = 0
                while (-not $task.IsCompleted) {
                    $size = 0L
                    if (Test-Path -LiteralPath $part) { $size = (Get-Item -LiteralPath $part).Length }
                    $percent = [Math]::Min(100, [Math]::Floor(100 * $size / $Dependency.bytes))
                    Write-Host ("`r     {0} {1} {2}  {3}%  {4:N1} MB    " -f $frames[$frame % 4], $Kind, $Dependency.version, $percent, ($size / 1MB)) -NoNewline -ForegroundColor DarkYellow
                    $frame++
                    if ($timer.Elapsed.TotalMinutes -gt 10) { $client.CancelAsync(); throw 'Dependency download timed out. Run setup again.' }
                    Start-Sleep -Milliseconds 120
                }
                [void]$task.GetAwaiter().GetResult()
                Write-Host ("`r     + {0} {1} downloaded                       " -f $Kind, $Dependency.version) -ForegroundColor Green
                if ((Get-FileSha256 $part) -ne $Dependency.sha256) { throw 'Dependency checksum mismatch. Existing installation is unchanged.' }
                Move-Item -LiteralPath $part -Destination $archive -Force
            } finally { $client.Dispose(); if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force } }
        }
    }
    if ((Get-FileSha256 $archive) -ne $Dependency.sha256) { throw 'Dependency checksum mismatch.' }
    Expand-Dependency $archive $destination $Dependency
    $executable = Join-Path $destination $Dependency.executable
    if (-not (Test-Runtime $Kind $executable)) { throw ('Portable runtime failed validation: ' + $Kind) }
    return $executable
}

function Read-Helper([string]$Directory, [string]$Script) {
    $lock = Join-Path $Directory 'button-helper.json'
    if (-not (Test-Path -LiteralPath $lock)) { return $null }
    try { $owner = [IO.File]::ReadAllText($lock) | ConvertFrom-Json }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    if ([string]$owner.pid -notmatch '^\d+$' -or -not $owner.instance -or -not $owner.script) { throw 'Invalid helper state. No process was changed.' }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.pid)"
    if (-not $process) {
        if (-not $DryRun) {
            try { [IO.File]::Delete($lock) }
            catch [IO.FileNotFoundException] { }
            catch [IO.DirectoryNotFoundException] { }
        }
        return $null
    }
    if ($process.Name -ne 'node.exe' -or [IO.Path]::GetFullPath($owner.script) -ne [IO.Path]::GetFullPath($Script) -or $process.CommandLine -notmatch ('(?:^|\s)"?' + [regex]::Escape($Script) + '"?(?:\s|$)')) { throw 'Helper ownership could not be verified. No process was changed.' }
    return $owner
}

function Stop-Helper($Config) {
    if (-not $Config -or -not $Config.bundleDir) { return }
    $directory = Join-Path $InstallRoot 'state'
    $scriptPath = Join-Path $Config.bundleDir 'ym-button-helper.mjs'
    $owner = Read-Helper $directory $scriptPath
    if (-not $owner -or $DryRun) { return }
    @{ instance = $owner.instance } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $directory 'button-helper-stop.json') -Encoding UTF8
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (Read-Helper $directory $scriptPath) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'A track is still downloading. Retry when it finishes; your download was not interrupted.' }
        Start-Sleep -Milliseconds 200
    }
}

function Find-App([string]$ExplicitPath) {
    if ($ExplicitPath) { $candidates = @($ExplicitPath) }
    else {
        $candidates = @((Join-Path $env:LOCALAPPDATA 'Programs\YandexMusic\Яндекс Музыка.exe'), (Join-Path $env:ProgramFiles 'YandexMusic\Яндекс Музыка.exe'))
        $keys = @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Яндекс Музыка|Yandex Music|YandexMusic' -and $_.InstallLocation })
        $candidates += @($keys | ForEach-Object { Join-Path $_.InstallLocation 'Яндекс Музыка.exe' })
    }
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return Get-CanonicalAppPath $candidate } }
    throw 'Install the Windows desktop Yandex Music app first, then run this setup again.'
}

function Validate-Package {
    foreach ($name in $sources) { if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $name) -PathType Leaf)) { throw ('Missing source file: ' + $name) } }
    foreach ($name in $rootFiles) { if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot ('..\' + $name)) -PathType Leaf)) { throw ('Missing package file: ' + $name) } }
    $dependencies = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($kind in @('node', 'python', 'ffmpeg')) {
        $dependency = $dependencies.$kind
        if ($dependency.sha256 -notmatch '^[a-f0-9]{64}$' -or ([uri]$dependency.url).Scheme -ne 'https' -or $dependency.directory -notmatch '^[a-z0-9.-]+$' -or $dependency.bytes -le 0) { throw 'Invalid dependency manifest.' }
    }
    return $dependencies
}

Write-Host "`n  YANDEX MUSIC ADDON" -ForegroundColor Yellow
Write-Host '  Track downloads / queue / native controls' -ForegroundColor DarkGray
if ($Action -eq 'Menu') {
    Write-Host "`n  [Enter / 1] Install or update`n  [2] Disable and restore shortcuts`n  [0] Exit`n"
    $choice = Read-Host '  Select'
    switch ($choice.Trim()) { '' { $Action = 'Install' }; '1' { $Action = 'Install' }; '2' { $Action = 'Uninstall' }; '0' { return }; default { throw 'Unknown menu option.' } }
}
$dependencies = Validate-Package
if ($Action -eq 'Check') { Write-Host '  Package and pinned dependency manifest verified.' -ForegroundColor Green; return }
if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Version.Major -lt 10) { throw 'Windows 10 or 11 x64 is required.' }
. (Join-Path $sourceRoot 'ym-shortcuts.ps1')
$mutex = New-YandexLifecycleMutex $InstallRoot 'Setup'
$ownsMutex = $false
$lifecycleMutex = $null
$ownsLifecycleMutex = $false
try {
    $ownsMutex = Enter-YandexLifecycleMutex $mutex 0
    if (-not $ownsMutex) { throw 'Another setup process is running.' }
    if ($Action -eq 'Uninstall') {
        $uninstaller = Join-Path $sourceRoot 'uninstall_music_autoload.ps1'
        & $uninstaller -InstallRoot $InstallRoot -DryRun:$DryRun
        return
    }
    Write-Step 'Locate the desktop app'
    $AppExe = Find-App $AppExe
    Write-Host ('     ' + $AppExe)
    $oldConfig = $null
    $oldConfigText = $null
    $oldConfigBytes = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) { $oldConfigBytes = [IO.File]::ReadAllBytes($configPath); $oldConfigText = Get-Content -LiteralPath $configPath -Raw; $oldConfig = $oldConfigText | ConvertFrom-Json }
    . (Join-Path $sourceRoot 'ym-shortcuts.ps1')
    $shell = New-YandexShortcutShell
    $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $launchVbs = Join-Path $InstallRoot 'launch_music_hidden.vbs'
    if (-not $ShortcutDirectories.Count) {
        $ShortcutDirectories = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('StartMenu'), (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')) | Where-Object { $_ } | Select-Object -Unique
    }
    $shortcuts = @()
    foreach ($directory in $ShortcutDirectories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue)) {
            $shortcut = $shell.CreateShortcut($file.FullName)
            if ($shortcut.TargetPath -and (Get-CanonicalAppPath $shortcut.TargetPath) -eq $AppExe) {
                $shortcuts += [pscustomobject]@{ path = $file.FullName; arguments = $shortcut.Arguments; created = $false; managed = $false; discoveredHash = (Get-FileSha256 $file.FullName) }
            } elseif ($shortcut.TargetPath -eq $wscriptExe) {
                $record = @($oldConfig.shortcuts | Where-Object { $_.path -eq $file.FullName }) | Select-Object -First 1
                if ($record -and $shortcut.Arguments -ceq $record.installedArguments) { $shortcuts += [pscustomobject]@{ path = $file.FullName; arguments = $record.originalArguments; created = [bool]$record.created; managed = $true; discoveredHash = (Get-FileSha256 $file.FullName) } }
            }
        }
    }
    $shortcuts = @($shortcuts | Sort-Object path -Unique)
    if (-not $shortcuts.Count) {
        $shortcutPath = Join-Path $ShortcutDirectories[0] 'Яндекс Музыка — с загрузками.lnk'
        if (Test-Path -LiteralPath $shortcutPath) { throw 'An unrelated shortcut occupies the addon shortcut path.' }
        $shortcuts = @([pscustomobject]@{ path = $shortcutPath; arguments = ''; created = $true; managed = $false; discoveredHash = $null })
    }
    Write-Step 'Verify addon files and shortcuts'
    $packageHash = Get-TextHash (($sources | ForEach-Object { $_ + ':' + (Get-FileSha256 (Join-Path $sourceRoot $_)) }) -join "`n")
    $bundleDir = Join-Path $InstallRoot ('bundles\' + $packageHash)
    if ($oldConfig) { Read-Helper (Join-Path $InstallRoot 'state') (Join-Path $oldConfig.bundleDir 'ym-button-helper.mjs') | Out-Null }
    foreach ($entry in $shortcuts) { Write-Host ('     ' + $entry.path) }
    Write-Step 'Prepare local portable runtimes'
    $NodeExe = Find-Runtime 'node' $NodeExe $oldConfig $dependencies.node
    $PythonExe = Find-Runtime 'python' $PythonExe $oldConfig $dependencies.python
    $FFmpegExe = Find-Runtime 'ffmpeg' $FFmpegExe $oldConfig $dependencies.ffmpeg
    if (-not $NodeExe) { $NodeExe = Get-Dependency 'node' $dependencies.node }
    if (-not $PythonExe) { $PythonExe = Get-Dependency 'python' $dependencies.python }
    if (-not $FFmpegExe) { $FFmpegExe = Get-Dependency 'ffmpeg' $dependencies.ffmpeg }
    foreach ($path in @($NodeExe, $PythonExe, $FFmpegExe)) { Write-Host ('     ' + $path) }
    if ($DryRun) { Write-Host "`n  Dry run complete: no files, processes, downloads or shortcuts changed." -ForegroundColor Green; return }
    $lifecycleMutex = New-YandexLifecycleMutex $InstallRoot
    $ownsLifecycleMutex = Enter-YandexLifecycleMutex $lifecycleMutex
    if (-not $ownsLifecycleMutex) { throw 'Another launcher or removal is changing addon state. Retry setup.' }
    Write-Step 'Save verified backups and install files'
    New-Item -ItemType Directory -Force -Path $bundleDir, (Join-Path $InstallRoot 'backups'), (Join-Path $InstallRoot 'state') | Out-Null
    foreach ($name in $sources) {
        $source = Join-Path $sourceRoot $name
        $target = Join-Path $bundleDir $name
        if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $source -Destination $target }
        if ((Get-FileSha256 $target) -ne (Get-FileSha256 $source)) { throw ('Existing bundle file is modified: ' + $name) }
    }
    $records = @($oldConfig.shortcuts | Where-Object { $_ })
    # Validate every original backup before stopping the old helper or changing a launch file.
    foreach ($record in $records) {
        if (-not (Test-Path -LiteralPath $record.backup -PathType Leaf)) { throw ('Shortcut backup is missing: ' + $record.backup) }
        if ($record.PSObject.Properties['backupSha256'] -and ($record.backupSha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileSha256 $record.backup) -ne $record.backupSha256.ToLowerInvariant())) { throw 'Shortcut backup checksum mismatch. No shortcuts were changed.' }
    }
    $shortcutBefore = @{}
    foreach ($entry in $shortcuts) {
        if ($entry.discoveredHash) {
            if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf) -or (Get-FileSha256 $entry.path) -ne $entry.discoveredHash) { throw ('Shortcut changed during setup; it was preserved: ' + $entry.path) }
        } elseif (Test-Path -LiteralPath $entry.path) { throw ('Shortcut appeared during setup; it was preserved: ' + $entry.path) }
        if ($entry.managed) { continue }
        Assert-YandexFileWritable $entry.path
        $shortcutBefore[$entry.path] = $null
        if (Test-Path -LiteralPath $entry.path -PathType Leaf) { $shortcutBefore[$entry.path] = [IO.File]::ReadAllBytes($entry.path) }
    }
    $startupBefore = @{}
    foreach ($name in ($startupFiles + $rootFiles)) {
        $path = Join-Path $InstallRoot $name
        Assert-YandexFileWritable $path
        $startupBefore[$path] = $null
        if (Test-Path -LiteralPath $path -PathType Leaf) { $startupBefore[$path] = [IO.File]::ReadAllBytes($path) }
    }
    Assert-YandexFileWritable $configPath
    $newBackups = @()
    $changedShortcuts = @()
    $changedStartup = @()
    $configChanged = $false
    $temporaryConfig = $configPath + '.new'
    try {
        foreach ($entry in $shortcuts) {
            $record = @($records | Where-Object { $_.path -eq $entry.path }) | Select-Object -First 1
            if ($record -and ($entry.managed -or (Get-FileSha256 $entry.path) -eq $record.backupSha256)) { continue }
            $key = Get-TextHash $entry.path.ToLowerInvariant()
            $backupName = $key
            if ($record) { $backupName += '-' + $entry.discoveredHash }
            $backup = Join-Path $InstallRoot ('backups\' + $backupName + '.lnk')
            if (Test-Path -LiteralPath $backup) { throw 'A shortcut backup has no configuration record. It was preserved.' }
            $newBackups += $backup
            if ($entry.created) {
                $shortcut = $shell.CreateShortcut($backup)
                $shortcut.TargetPath = $AppExe
                $shortcut.IconLocation = $AppExe + ',0'
                $shortcut.Save()
            } else { [IO.File]::WriteAllBytes($backup, $shortcutBefore[$entry.path]) }
            $records = @($records | Where-Object { $_.path -ne $entry.path })
            $records += [pscustomobject]@{ path = $entry.path; key = $key; backup = $backup; originalArguments = $entry.arguments; installedArguments = ('"' + $launchVbs + '" --shortcut-key ' + $key); created = $entry.created; backupSha256 = (Get-FileSha256 $backup) }
        }
        if ($oldConfig -and $oldConfig.bundleDir -ne $bundleDir) { Stop-Helper $oldConfig }
        foreach ($name in ($startupFiles + $rootFiles)) {
            $target = Join-Path $InstallRoot $name
            $changedStartup += $target
            $source = if ($name -in $rootFiles) { Join-Path $PSScriptRoot ('..\' + $name) } else { Join-Path $sourceRoot $name }
            Copy-YandexAtomicFile $source $target
        }
        $configuration = @{ enabled = $true; bundleDir = $bundleDir; bundleHash = $packageHash; appExe = $AppExe; pythonExe = $PythonExe; nodeExe = $NodeExe; ffmpegExe = $FFmpegExe; shortcuts = @($records); installerVersion = 1 }
        $configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryConfig -Encoding UTF8
        $configChanged = $true
        Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force
        Write-Step 'Connect ordinary app shortcuts'
        foreach ($entry in $shortcuts) {
            if ($entry.managed) { continue }
            $record = @($records | Where-Object { $_.path -eq $entry.path }) | Select-Object -First 1
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $entry.path) | Out-Null
            $shortcut = $shell.CreateShortcut($entry.path)
            $icon = $shortcut.IconLocation
            if (-not $icon) { $icon = $AppExe + ',0' }
            $shortcut.TargetPath = $wscriptExe
            $shortcut.Arguments = $record.installedArguments
            $shortcut.IconLocation = $icon
            $changedShortcuts += $entry.path
            $shortcut.Save()
            $record | Add-Member -NotePropertyName installedSha256 -NotePropertyValue (Get-FileSha256 $entry.path) -Force
        }
        $configuration | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryConfig -Encoding UTF8
        Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force
    } catch {
        # Restore exact pre-update files; original backups are exclusively for uninstall.
        $failure = $_
        $rollbackErrors = @()
        foreach ($path in $changedShortcuts) {
            try {
                if ($null -ne $shortcutBefore[$path]) { [IO.File]::WriteAllBytes($path, $shortcutBefore[$path]) }
                elseif (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
            } catch { $rollbackErrors += ($path + ': ' + $_.Exception.Message) }
        }
        foreach ($path in $changedStartup) {
            try {
                if ($null -ne $startupBefore[$path]) { Write-YandexAtomicBytes $path $startupBefore[$path] }
                elseif (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
            } catch { $rollbackErrors += ($path + ': ' + $_.Exception.Message) }
        }
        try {
            if ($configChanged) {
                if ($null -ne $oldConfigBytes) { [IO.File]::WriteAllBytes($configPath, $oldConfigBytes) }
                elseif (Test-Path -LiteralPath $configPath -PathType Leaf) { Remove-Item -LiteralPath $configPath -Force }
            }
        } catch { $rollbackErrors += ($configPath + ': ' + $_.Exception.Message) }
        # Keep newly created backups if any restoration failed: an unwritable
        # shortcut may still need its original bytes for manual recovery.
        $cleanup = @($temporaryConfig)
        if (-not $rollbackErrors.Count) { $cleanup += $newBackups }
        foreach ($path in $cleanup) {
            try { if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force } }
            catch { $rollbackErrors += ($path + ': ' + $_.Exception.Message) }
        }
        if ($rollbackErrors.Count) { throw ($failure.Exception.Message + ' Rollback could not restore: ' + ($rollbackErrors -join '; ')) }
        throw $failure
    }
    Write-Host "`n  + Installed. Open Yandex Music using its usual shortcut." -ForegroundColor Green
    Write-Host '  If it was already running normally, close it once and reopen.'
    Write-Host '  Your app EXE/ASAR, songs, login and download history are preserved.' -ForegroundColor DarkGray
    Write-Host '  Run this same setup file and choose 2 to disable the addon.' -ForegroundColor DarkGray
} finally {
    if ($ownsLifecycleMutex) { $lifecycleMutex.ReleaseMutex() }
    if ($lifecycleMutex) { $lifecycleMutex.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }; $mutex.Dispose()
}
