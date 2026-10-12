param([string]$DependencyArchiveDirectory = '')
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installer = Join-Path $repository 'installer\install.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('YandexMusicAddon-Test-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $fixture 'addon'
$shortcutDirectory = Join-Path $fixture 'shortcuts'
$fakeApp = Join-Path $fixture 'fake-app\Яндекс Музыка.exe'
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fakeApp), $shortcutDirectory | Out-Null
    # Windows Shell versions differ in whether .lnk targets may be text files
    # named .exe. Use a valid local PE while keeping the Cyrillic test path.
    # This fixture target is never launched by either setup or these tests.
    [IO.File]::Copy((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'), $fakeApp)
    Write-Host ('Fixture app: {0}; exists={1}; chars={2}; x64={3}; apartment={4}; PowerShell={5}' -f $fakeApp, [IO.File]::Exists($fakeApp), $fakeApp.Length, [Environment]::Is64BitProcess, [Threading.Thread]::CurrentThread.ApartmentState, $PSVersionTable.PSVersion)
    . (Join-Path $repository 'src\ym-shortcuts.ps1')
    $shell = New-YandexShortcutShell
    $shortcutPath = Join-Path $shortcutDirectory 'Fixture Music.lnk'
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $fakeApp
    $shortcut.Arguments = '--fixture "two words"'
    $shortcut.IconLocation = $fakeApp + ',0'
    $shortcut.WorkingDirectory = Split-Path -Parent $fakeApp
    $shortcut.Save()
    $originalHash = Hash $shortcutPath
    $originalArguments = $shortcut.Arguments
    # Three tiny local version probes keep shortcut/rollback tests independent of the
    # runner's installed runtimes and network. The optional portable test uses real ZIPs.
    $probeDirectory = Join-Path $fixture 'runtime-probes'
    New-Item -ItemType Directory -Force -Path $probeDirectory | Out-Null
    $probe = Join-Path $probeDirectory 'version-probe.exe'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
class AddonInstallerRuntimeProbe {
    static void Main() {
        string name = Path.GetFileName(Process.GetCurrentProcess().MainModule.FileName).ToLowerInvariant();
        Console.WriteLine(name == "node.exe" ? "v22.0.0" : name == "python.exe" ? "3.12" : "ffmpeg version 6.0 fixture");
    }
}
'@ -OutputAssembly $probe -OutputType ConsoleApplication
    foreach ($kind in @('node', 'python', 'ffmpeg')) { Copy-Item -LiteralPath $probe -Destination (Join-Path $probeDirectory ($kind + '.exe')) }
    $options = @{ Action = 'Install'; InstallRoot = $installRoot; AppExe = $fakeApp; ShortcutDirectories = @($shortcutDirectory); NodeExe = (Join-Path $probeDirectory 'node.exe'); PythonExe = (Join-Path $probeDirectory 'python.exe'); FFmpegExe = (Join-Path $probeDirectory 'ffmpeg.exe') }
    & $installer @options -DryRun
    Assert (-not (Test-Path -LiteralPath $installRoot)) 'Dry run created installation files.'
    Assert ((Hash $shortcutPath) -eq $originalHash) 'Dry run changed shortcut.'
    $state = Join-Path $installRoot 'state'
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $history = Join-Path $state 'downloads.json'
    $session = Join-Path $state '.yandex-music-session.dpapi'
    [IO.File]::WriteAllText($history, '{"jobs":[],"fixture":true}')
    [IO.File]::WriteAllText($session, 'Fake protected-session fixture, never used.')
    $historyHash = Hash $history
    $sessionHash = Hash $session
    & $installer @options
    $configPath = Join-Path $installRoot 'config.json'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert ($config.enabled -eq $true) 'Configuration not enabled.'
    Assert (@($config.shortcuts).Count -eq 1) 'Unexpected shortcut records.'
    Assert ((Hash $config.shortcuts[0].backup) -eq $originalHash) 'Backup does not preserve original bytes.'
    Assert (@(Get-ChildItem -LiteralPath $config.bundleDir -File).Count -eq 11) 'Bundle is not the 11-source allowlist.'
    $updatedShortcut = $shell.CreateShortcut($shortcutPath)
    Assert ([YandexMusicAddon.InstallerPaths]::Canonicalize($updatedShortcut.WorkingDirectory) -eq [YandexMusicAddon.InstallerPaths]::Canonicalize((Split-Path -Parent $fakeApp))) ('Updating target/arguments discarded existing Unicode working directory: actual=' + $updatedShortcut.WorkingDirectory + '; expected=' + (Split-Path -Parent $fakeApp))
    $updatedIcon = $updatedShortcut.IconLocation
    Assert ($updatedIcon.EndsWith(',0') -and [YandexMusicAddon.InstallerPaths]::Canonicalize($updatedIcon.Substring(0, $updatedIcon.Length - 2)) -eq [YandexMusicAddon.InstallerPaths]::Canonicalize($fakeApp)) ('Updating target/arguments discarded existing Unicode icon location: actual=' + $updatedIcon + '; expected=' + $fakeApp + ',0')
    Assert (Test-Path -LiteralPath (Join-Path $installRoot 'ym-shortcuts.ps1') -PathType Leaf) 'Native shortcut module was not copied for installed uninstaller.'
    foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) { Assert ((Hash (Join-Path $installRoot $name)) -eq (Hash (Join-Path $repository $name))) 'Package license/notice was not installed.' }
    Assert ((Hash $history) -eq $historyHash -and (Hash $session) -eq $sessionHash) 'Installer modified private state.'
    $backupHash = Hash $config.shortcuts[0].backup
    $backupTimestamp = (Get-Item -LiteralPath $config.shortcuts[0].backup).LastWriteTimeUtc
    & $installer @options
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert (@($config.shortcuts).Count -eq 1) 'Reinstall duplicated records.'
    Assert ((Hash $config.shortcuts[0].backup) -eq $backupHash -and (Get-Item -LiteralPath $config.shortcuts[0].backup).LastWriteTimeUtc -eq $backupTimestamp) 'Reinstall replaced backup.'
    $backupBytes = [IO.File]::ReadAllBytes($config.shortcuts[0].backup)
    $beforeTamperShortcut = Hash $shortcutPath
    $beforeTamperConfig = Hash $configPath
    [IO.File]::WriteAllText($config.shortcuts[0].backup, 'Corrupt fixture backup.')
    $tamperRejected = $false
    try { & $installer @options } catch { $tamperRejected = $_.Exception.Message -match 'backup checksum' }
    Assert $tamperRejected 'Tampered backup was accepted by installer.'
    Assert ((Hash $shortcutPath) -eq $beforeTamperShortcut -and (Hash $configPath) -eq $beforeTamperConfig) 'Tampered backup check changed active installation.'
    [IO.File]::WriteAllBytes($config.shortcuts[0].backup, $backupBytes)
    [IO.File]::WriteAllText((Join-Path $installRoot 'launch_music_hidden.vbs'), 'Original fixture launch file; never executed.')
    $launchHashes = @{}
    foreach ($name in @('launch_music_hidden.vbs', 'launch_music_installed.ps1', 'uninstall_music_autoload.ps1', 'ym-shortcuts.ps1')) { $launchHashes[$name] = Hash (Join-Path $installRoot $name) }
    function Copy-Item {
        [CmdletBinding()]param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        if ($Destination.StartsWith((Join-Path $installRoot 'launch_music_installed.ps1') + '.')) { throw 'Injected fixture startup-copy failure.' }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
    $rollbackRejected = $false
    try { & $installer @options } catch { $rollbackRejected = $_.Exception.Message -match 'fixture startup-copy failure' }
    finally { Remove-Item -LiteralPath 'Function:\Copy-Item' -Force }
    Assert $rollbackRejected 'Rollback failure fixture did not trigger.'
    Assert ((Hash $shortcutPath) -eq $beforeTamperShortcut -and (Hash $configPath) -eq $beforeTamperConfig) 'Update rollback lost previous shortcut/configuration.'
    foreach ($name in $launchHashes.Keys) { Assert ((Hash (Join-Path $installRoot $name)) -eq $launchHashes[$name]) 'Update rollback lost previous launcher bytes.' }
    $installedShortcutHash = Hash $shortcutPath
    & $installer -Action Uninstall -InstallRoot $installRoot -DryRun
    Assert ((Hash $shortcutPath) -eq $installedShortcutHash) 'Uninstall dry run changed shortcut.'
    & $installer -Action Uninstall -InstallRoot $installRoot
    Assert ((Hash $shortcutPath) -eq $originalHash) 'Uninstall did not restore exact shortcut bytes.'
    Assert ((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).enabled -eq $false) 'Uninstall did not disable configuration.'
    Assert ((Hash $history) -eq $historyHash -and (Hash $session) -eq $sessionHash) 'Uninstall changed private state.'
    & $installer @options
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    [IO.File]::WriteAllText((Join-Path $state 'button-helper.json'), (@{ pid = $PID; script = (Join-Path $config.bundleDir 'ym-button-helper.mjs'); instance = 'foreign-fixture' } | ConvertTo-Json))
    $ownershipRejected = $false
    try { & $installer @options -DryRun } catch { $ownershipRejected = $_.Exception.Message -match 'ownership' }
    Assert $ownershipRejected 'Foreign helper PID was not rejected.'
    Remove-Item -LiteralPath (Join-Path $state 'button-helper.json') -Force
    $raceLock = Join-Path $state 'button-helper.json'
    $raceOwner = @{ pid = 2147483647; script = (Join-Path $config.bundleDir 'ym-button-helper.mjs'); instance = 'disappearing-fixture' } | ConvertTo-Json
    [IO.File]::WriteAllText($raceLock, $raceOwner)
    $raceMarker = @{ read = $false; delete = $false }
    function Test-Path {
        [CmdletBinding()]param([string]$LiteralPath, [string]$Path, [string]$PathType)
        $exists = Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        if ($LiteralPath -eq $raceLock -and -not $raceMarker.read) {
            [IO.File]::Delete($raceLock)
            $raceMarker.read = $true
        }
        return $exists
    }
    try { & $installer @options -DryRun }
    finally { Remove-Item -LiteralPath 'Function:\Test-Path' -Force }
    Assert ($raceMarker.read -and -not (Test-Path -LiteralPath $raceLock)) 'Disappearing-lock read fixture did not execute.'
    [IO.File]::WriteAllText($raceLock, $raceOwner)
    function Get-CimInstance {
        [CmdletBinding()]param([string]$ClassName, [string]$Filter)
        if ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=2147483647') {
            [IO.File]::Delete($raceLock)
            $raceMarker.delete = $true
            return $null
        }
        CimCmdlets\Get-CimInstance @PSBoundParameters
    }
    try { & $installer @options }
    finally { Remove-Item -LiteralPath 'Function:\Get-CimInstance' -Force }
    Assert ($raceMarker.delete -and -not (Test-Path -LiteralPath $raceLock)) 'Disappearing stale-lock cleanup fixture did not execute.'
    [IO.File]::WriteAllText($raceLock, '{malformed-json')
    $malformedRejected = $false
    try { & $installer @options -DryRun } catch { $malformedRejected = $true }
    Assert $malformedRejected 'Malformed lock was swallowed by missing-file handling.'
    [IO.File]::Delete($raceLock)
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
    $shortcut.Arguments = '--manual-fixture-change'
    $shortcut.Save()
    $manualHash = Hash $shortcutPath
    & $installer -Action Uninstall -InstallRoot $installRoot
    Assert ((Hash $shortcutPath) -eq $manualHash) 'Uninstall overwrote independent shortcut change.'
    $emptyShortcuts = Join-Path $fixture 'empty-shortcuts'
    New-Item -ItemType Directory -Force -Path $emptyShortcuts | Out-Null
    $fallbackOptions = $options.Clone()
    $fallbackOptions.InstallRoot = Join-Path $fixture 'fallback-addon'
    $fallbackOptions.ShortcutDirectories = @($emptyShortcuts)
    & $installer @fallbackOptions
    $fallbackConfig = Get-Content -LiteralPath (Join-Path $fallbackOptions.InstallRoot 'config.json') -Raw | ConvertFrom-Json
    Assert ($fallbackConfig.shortcuts[0].created -eq $true) 'Managed shortcut was not created when no app shortcut exists.'
    & $installer -Action Uninstall -InstallRoot $fallbackOptions.InstallRoot
    Assert ($shell.CreateShortcut($fallbackConfig.shortcuts[0].path).TargetPath -eq [YandexMusicAddon.InstallerPaths]::Canonicalize($fakeApp)) 'Managed shortcut did not revert to original app.'
    Add-Type -TypeDefinition @'
using System.Text;
using System.Runtime.InteropServices;
public class AddonInstallerAliasProbe {
    [DllImport("kernel32.dll", EntryPoint="GetShortPathNameW", ExactSpelling=true, CharSet=CharSet.Unicode)]
    public static extern uint GetShortPathName(string path, StringBuilder value, uint count);
}
'@
    $aliasBuffer = New-Object Text.StringBuilder(32768)
    $aliasLength = [AddonInstallerAliasProbe]::GetShortPathName($fakeApp, $aliasBuffer, 32768)
    Assert ($aliasLength -gt 0) 'Could not inspect existing fixture executable short path.'
    $aliasApp = $aliasBuffer.ToString()
    $aliasDirectory = Join-Path $fixture 'alias-shortcuts'
    New-Item -ItemType Directory -Force -Path $aliasDirectory | Out-Null
    $aliasShortcutPath = Join-Path $aliasDirectory 'Alias Fixture.lnk'
    $aliasShortcut = $shell.CreateShortcut($aliasShortcutPath)
    $aliasShortcut.TargetPath = $fakeApp
    $aliasShortcut.Save()
    $aliasOriginalHash = Hash $aliasShortcutPath
    $aliasOptions = $options.Clone()
    $aliasOptions.InstallRoot = Join-Path $fixture 'alias-addon'
    $aliasOptions.ShortcutDirectories = @($aliasDirectory)
    $aliasOptions.AppExe = $aliasApp
    & $installer @aliasOptions
    $aliasConfig = Get-Content -LiteralPath (Join-Path $aliasOptions.InstallRoot 'config.json') -Raw | ConvertFrom-Json
    Assert ($aliasConfig.shortcuts[0].path -eq $aliasShortcutPath -and -not $aliasConfig.shortcuts[0].created) 'Existing shortcut was not found through equivalent app path.'
    Assert ($aliasConfig.appExe -eq [YandexMusicAddon.InstallerPaths]::Canonicalize($fakeApp)) 'App path was not canonicalized.'
    & $installer -Action Uninstall -InstallRoot $aliasOptions.InstallRoot
    Assert ((Hash $aliasShortcutPath) -eq $aliasOriginalHash) 'Alias installation did not restore exact original shortcut bytes.'
    Write-Host ('PASS: equivalent app-path discovery and exact rollback; input=' + $aliasApp + '; canonical=' + $aliasConfig.appExe)
    foreach ($legacy in @($false, $true)) {
        $customOptions = $options.Clone()
        $customOptions.InstallRoot = Join-Path $fixture ('custom-addon-' + $legacy)
        $customDirectory = Join-Path $fixture ('custom-shortcuts-' + $legacy)
        New-Item -ItemType Directory -Force -Path $customDirectory | Out-Null
        $customOptions.ShortcutDirectories = @($customDirectory)
        $customPath = Join-Path $customDirectory 'Custom Music.lnk'
        $custom = $shell.CreateShortcut($customPath)
        $custom.TargetPath = $fakeApp; $custom.Arguments = '--original'; $custom.Save()
        & $installer @customOptions
        $customConfigPath = Join-Path $customOptions.InstallRoot 'config.json'
        if ($legacy) {
            $legacyConfig = Get-Content -LiteralPath $customConfigPath -Raw | ConvertFrom-Json
            $legacyConfig.shortcuts[0].PSObject.Properties.Remove('installedSha256')
            $legacyConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $customConfigPath -Encoding UTF8
        }
        $custom = $shell.CreateShortcut($customPath)
        $custom.IconLocation = (Join-Path $env:SystemRoot 'System32\notepad.exe') + ',2'
        $custom.WorkingDirectory = $fixture
        $custom.Hotkey = 1601; $custom.WindowStyle = 3; $custom.Description = 'My custom shortcut'
        $custom.Save(); $customHash = Hash $customPath
        & $installer @customOptions
        Assert ((Hash $customPath) -eq $customHash) 'Update rewrote manually customized managed link.'
        & $installer -Action Uninstall -InstallRoot $customOptions.InstallRoot
        $restored = $shell.CreateShortcut($customPath)
        Assert ($restored.TargetPath -eq [YandexMusicAddon.InstallerPaths]::Canonicalize($fakeApp) -and $restored.Arguments -eq '--original') 'Customized link did not remove addon-owned fields.'
        Assert ($restored.IconLocation -eq $custom.IconLocation -and $restored.WorkingDirectory -eq $custom.WorkingDirectory -and $restored.Hotkey -eq 1601 -and $restored.WindowStyle -eq 3 -and $restored.Description -eq 'My custom shortcut') 'Removal discarded manual metadata.'
    }
    $customOptions.InstallRoot = Join-Path $fixture 'custom-argv-addon'
    & $installer @customOptions
    $customConfigPath = Join-Path $customOptions.InstallRoot 'config.json'
    $customConfig = Get-Content -LiteralPath $customConfigPath -Raw | ConvertFrom-Json
    $savedBackup = $customConfig.shortcuts[0].backup; $savedBackupHash = Hash $savedBackup
    $custom = $shell.CreateShortcut($customPath)
    $custom.Arguments += ' --my-added-argument'; $custom.Save(); $argvHash = Hash $customPath
    & $installer @customOptions
    Assert ((Hash $customPath) -eq $argvHash) 'Update discarded manually added managed arguments.'
    & $installer -Action Uninstall -InstallRoot $customOptions.InstallRoot
    Assert ((Hash $customPath) -eq $argvHash) 'Removal discarded manually added managed arguments.'
    # A manually restored native target/argv is a new baseline, while the old
    # original backup remains intact for recovery and audit.
    $custom = $shell.CreateShortcut($customPath)
    $custom.TargetPath = $fakeApp; $custom.Arguments = '--new-native "two words"'; $custom.Save()
    $nativeHash = Hash $customPath
    & $installer @customOptions
    $customConfig = Get-Content -LiteralPath $customConfigPath -Raw | ConvertFrom-Json
    $nativeRecord = @($customConfig.shortcuts | Where-Object { $_.path -eq $customPath })[0]
    Assert ($nativeRecord.originalArguments -eq '--new-native "two words"') 'Rehook retained stale original argv.'
    Assert ((Hash $savedBackup) -eq $savedBackupHash) 'Rehook replaced an original backup.'
    & $installer -Action Uninstall -InstallRoot $customOptions.InstallRoot
    Assert ((Hash $customPath) -eq $nativeHash) 'Rehook removal did not restore the manual native baseline.'
    $failureOptions = $options.Clone()
    $failureOptions.InstallRoot = Join-Path $fixture 'failure-addon'
    $failureDirectory = Join-Path $fixture 'failure-shortcuts'
    New-Item -ItemType Directory -Force -Path $failureDirectory | Out-Null
    $failureOptions.ShortcutDirectories = @($failureDirectory)
    $failurePaths = @((Join-Path $failureDirectory 'A.lnk'), (Join-Path $failureDirectory 'B.lnk'))
    $failureBytes = @{}
    foreach ($path in $failurePaths) { $link = $shell.CreateShortcut($path); $link.TargetPath = $fakeApp; $link.Save(); $failureBytes[$path] = [IO.File]::ReadAllBytes($path) }
    [IO.File]::SetAttributes($failurePaths[0], [IO.FileAttributes]::ReadOnly)
    $preflightRejected = $false
    try { & $installer @failureOptions } catch { $preflightRejected = $_.Exception.Message -match 'read-only' }
    finally { [IO.File]::SetAttributes($failurePaths[0], [IO.FileAttributes]::Normal) }
    Assert ($preflightRejected -and -not (Test-Path -LiteralPath (Join-Path $failureOptions.InstallRoot 'config.json'))) 'Read-only shortcut was not rejected before config commit.'
    $held = [IO.File]::Open($failurePaths[0], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $preflightRejected = $false
    try { & $installer @failureOptions } catch { $preflightRejected = $true } finally { $held.Dispose() }
    Assert ($preflightRejected -and -not (Test-Path -LiteralPath (Join-Path $failureOptions.InstallRoot 'config.json'))) 'Write-locked shortcut was not rejected before config commit.'
    $rollbackFixture = @{ moves = 0; held = $null }
    function Move-Item {
        [CmdletBinding()]param([string]$LiteralPath, [string]$Destination, [switch]$Force)
        if ($Destination -eq (Join-Path $failureOptions.InstallRoot 'config.json')) {
            $rollbackFixture.moves++
            if ($rollbackFixture.moves -eq 2) {
                $rollbackFixture.held = [IO.File]::Open($failurePaths[0], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                throw 'Injected fixture post-shortcut failure.'
            }
        }
        Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
    }
    $aggregateRejected = $false
    try { & $installer @failureOptions }
    catch { $aggregateRejected = $_.Exception.Message -match 'post-shortcut failure.*Rollback could not restore' }
    finally { Remove-Item -LiteralPath 'Function:\Move-Item' -Force; if ($rollbackFixture.held) { $rollbackFixture.held.Dispose() } }
    Assert $aggregateRejected 'Unwritable rollback did not report aggregate failure.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $failureOptions.InstallRoot 'config.json'))) 'Unwritable shortcut prevented config rollback.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $failureOptions.InstallRoot 'launch_music_installed.ps1'))) 'Unwritable shortcut prevented launcher rollback.'
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($failurePaths[1])) -eq [Convert]::ToBase64String($failureBytes[$failurePaths[1]])) 'Unwritable shortcut prevented another shortcut rollback.'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $failureOptions.InstallRoot 'backups') -Filter '*.lnk').Count -eq 2) 'Failed rollback deleted recovery backups.'
    foreach ($path in $failurePaths) { [IO.File]::WriteAllBytes($path, $failureBytes[$path]) }
    Write-Host 'PASS: manual argv/native baselines, modern/legacy metadata preservation, writable preflight, independent rollback recovery, and installed notices.'
    if ($DependencyArchiveDirectory) {
        $portableOptions = $options.Clone()
        $portableOptions.InstallRoot = Join-Path $fixture 'portable'
        $portableOptions.ShortcutDirectories = @((Join-Path $fixture 'portable-shortcuts'))
        $portableOptions.Remove('NodeExe')
        $portableOptions.Remove('PythonExe')
        $portableOptions.Remove('FFmpegExe')
        & $installer @portableOptions -ForcePortable -DependencyArchiveDirectory $DependencyArchiveDirectory
        $portableConfig = Get-Content -LiteralPath (Join-Path $portableOptions.InstallRoot 'config.json') -Raw | ConvertFrom-Json
        . $installer -Action Check -InstallRoot $portableOptions.InstallRoot -DependencyArchiveDirectory $DependencyArchiveDirectory
        foreach ($kind in @('node', 'python', 'ffmpeg')) {
            $path = $portableConfig.($kind + 'Exe')
            Assert (Test-Runtime $kind $path) ('Pinned portable runtime failed: ' + $kind)
        }
        & $portableConfig.pythonExe (Join-Path $portableConfig.bundleDir 'yandex_music_button.py') --help | Out-Null
        Assert ($LASTEXITCODE -eq 0) 'Embeddable Python could not import the bundled sibling module.'
        & $installer -Action Uninstall -InstallRoot $portableOptions.InstallRoot
    }
    Write-Host 'PASS: dry run, install, reinstall, exact uninstall, preserved state, foreign PID rejection, independent changes, corrupt-backup rejection, transactional update rollback, lock disappearance races, malformed-lock rejection.' -ForegroundColor Green
    if ($DependencyArchiveDirectory) { Write-Host 'PASS: genuine pinned portable Node, Python and FFmpeg archives.' -ForegroundColor Green }
} finally {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetFullPath((Split-Path -Parent $fixture)).TrimEnd('\') -ne $tempRoot -or (Split-Path -Leaf $fixture) -notmatch '^YandexMusicAddon-Test-[a-f0-9]{32}$') { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
