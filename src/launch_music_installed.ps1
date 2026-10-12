param([string]$ForwardArgsJson = '[]', [string]$ShortcutKey = '', [string]$InstallRoot = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$addonRoot = [IO.Path]::GetFullPath($InstallRoot)

function ConvertTo-NativeArgument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Read-HelperLockText([string]$Path) {
    try { return [IO.File]::ReadAllText($Path) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
}

function Read-HelperOwner([string]$Directory, [string]$Script) {
    $lock = Join-Path $Directory 'button-helper.json'
    if (-not (Test-Path -LiteralPath $lock)) { return $null }
    $lockText = Read-HelperLockText $lock
    if ($null -eq $lockText) { return $null }
    $owner = $lockText | ConvertFrom-Json
    if ([string]$owner.pid -notmatch '^\d+$' -or -not $owner.instance -or -not $owner.script) { throw 'Invalid helper lock.' }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.pid)"
    if (-not $process) {
        try { [IO.File]::Delete($lock) }
        catch [IO.FileNotFoundException] {}
        catch [IO.DirectoryNotFoundException] {}
        return $null
    }
    if ($process.Name -ne 'node.exe' -or [IO.Path]::GetFullPath($owner.script) -ne [IO.Path]::GetFullPath($Script) -or $process.CommandLine -notmatch ('(?:^|\s)"?' + [regex]::Escape($Script) + '"?(?:\s|$)')) {
        throw 'Helper lock does not match the installed helper process.'
    }
    return $owner
}

function Stop-OwnedHelper([string]$Directory, [string]$Script) {
    $owner = Read-HelperOwner $Directory $Script
    if (-not $owner) { return }
    $stop = Join-Path $Directory 'button-helper-stop.json'
    @{ instance = $owner.instance } | ConvertTo-Json -Compress | Set-Content -LiteralPath $stop -Encoding UTF8
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (Read-HelperOwner $Directory $Script) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'A download is finishing. Retry after it completes; no process was killed.' }
        Start-Sleep -Milliseconds 200
    }
}

$lifecycleMutex = $null
$ownsLifecycleMutex = $false
try {
    . (Join-Path $PSScriptRoot 'ym-shortcuts.ps1')
    $lifecycleMutex = New-YandexLifecycleMutex $addonRoot
    $ownsLifecycleMutex = Enter-YandexLifecycleMutex $lifecycleMutex
    if (-not $ownsLifecycleMutex) { throw 'Setup is changing addon state. Retry opening the app.' }
    $previousError = Join-Path $addonRoot 'state\launcher-error.txt'
    if (Test-Path -LiteralPath $previousError) { Clear-Content -LiteralPath $previousError -ErrorAction SilentlyContinue }
    $config = Get-Content -LiteralPath (Join-Path $addonRoot 'config.json') -Raw | ConvertFrom-Json
    $forward = @()
    if ($ForwardArgsJson -notmatch '^\s*\[\s*\]\s*$') {
        if ($ForwardArgsJson.TrimStart()[0] -ne '[') { throw 'Application arguments must be a JSON array.' }
        $forward = @(ConvertFrom-Json -InputObject $ForwardArgsJson)
    }
    foreach ($argument in $forward) { if ($argument -isnot [string] -or $argument.Contains([char]0)) { throw 'Invalid application argument.' } }
    $nativeArgs = @()
    if ($config.enabled -ne $false) { $nativeArgs += '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=9229' }
    $nativeArgs += $forward
    $argumentLine = (($nativeArgs | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    if ($ShortcutKey) {
        if ($ShortcutKey -notmatch '^[a-f0-9]{64}$') { throw 'Invalid shortcut identifier.' }
        $record = @($config.shortcuts | Where-Object { $_.key -eq $ShortcutKey }) | Select-Object -First 1
        if (-not $record) { throw 'Shortcut record is unavailable.' }
        # Preserve the original native argv; wscript parses literal quotes differently.
        if ($record.originalArguments) { $argumentLine += ' ' + $record.originalArguments }
    }
    if ($argumentLine) { Start-Process -FilePath $config.appExe -ArgumentList $argumentLine | Out-Null }
    else { Start-Process -FilePath $config.appExe | Out-Null }
    if ($config.enabled -eq $false) { exit 0 }
    if ($config.legacyWork -and $config.legacyScript) { Stop-OwnedHelper $config.legacyWork $config.legacyScript }
    $work = Join-Path $addonRoot 'state'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $script = Join-Path $config.bundleDir 'ym-button-helper.mjs'
    $existing = Read-HelperOwner $work $script
    if ($existing) { exit 0 }
    $env:YM_WORK_DIR = $work
    $env:YM_PYTHON = $config.pythonExe
    $env:YM_NODE = $config.nodeExe
    $env:YM_FFMPEG = $config.ffmpegExe
    $env:YM_APP_ASAR = Join-Path (Split-Path -Parent $config.appExe) 'resources\app.asar'
    $env:YM_APP_PORT = '9229'
    $env:PATH = (Split-Path -Parent $config.nodeExe) + ';' + (Split-Path -Parent $config.ffmpegExe) + ';' + $env:PATH
    $helperProcess = Start-Process -FilePath $config.nodeExe -ArgumentList (ConvertTo-NativeArgument $script) -WorkingDirectory $config.bundleDir -WindowStyle Hidden -RedirectStandardOutput (Join-Path $work 'button-helper.out.log') -RedirectStandardError (Join-Path $work 'button-helper.err.log') -PassThru
    try {
        # Keep the lifecycle lock until setup can observe this child. Releasing
        # it immediately after Start-Process leaves an unregistered old helper
        # free to acquire its state lock after an update has already committed.
        while (-not $helperProcess.HasExited) {
            $owner = Read-HelperOwner $work $script
            if ($owner -and $owner.pid -eq $helperProcess.Id) { break }
            Start-Sleep -Milliseconds 100
        }
        if ($helperProcess.HasExited -and $helperProcess.ExitCode -ne 0) { throw 'The addon helper could not start. See its error log.' }
    } finally { $helperProcess.Dispose() }
} catch {
    $errorDirectory = Join-Path $addonRoot 'state'
    New-Item -ItemType Directory -Force -Path $errorDirectory | Out-Null
    $_.Exception.Message | Set-Content -LiteralPath (Join-Path $errorDirectory 'launcher-error.txt') -Encoding UTF8
    exit 1
} finally {
    if ($ownsLifecycleMutex) { $lifecycleMutex.ReleaseMutex() }
    if ($lifecycleMutex) { $lifecycleMutex.Dispose() }
}
