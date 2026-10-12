param([switch]$DryRun, [string]$InstallRoot = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$installRoot = [IO.Path]::GetFullPath($InstallRoot)

function Get-BackupSha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '') }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Read-HelperLockText([string]$Path) {
    try { return [IO.File]::ReadAllText($Path) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
}

$shortcutModule = Join-Path $PSScriptRoot 'ym-shortcuts.ps1'
if (-not (Test-Path -LiteralPath $shortcutModule)) { $shortcutModule = Join-Path $installRoot 'ym-shortcuts.ps1' }
. $shortcutModule
$setupMutex = New-YandexLifecycleMutex $installRoot 'Setup'
$lifecycleMutex = New-YandexLifecycleMutex $installRoot
$ownsSetupMutex = $false
$ownsLifecycleMutex = $false
try {
$ownsSetupMutex = Enter-YandexLifecycleMutex $setupMutex 0
if (-not $ownsSetupMutex) { throw 'Another setup process is running. Retry removal.' }
$ownsLifecycleMutex = Enter-YandexLifecycleMutex $lifecycleMutex
if (-not $ownsLifecycleMutex) { throw 'A launcher is changing addon state. Retry removal.' }
$configPath = Join-Path $installRoot 'config.json'
if (-not (Test-Path -LiteralPath $configPath)) { Write-Host 'Автоматическое подключение не установлено.'; return }
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$shell = New-YandexShortcutShell
$wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
$restore = @()
foreach ($record in $config.shortcuts) {
    if (-not (Test-Path -LiteralPath $record.path)) { continue }
    $shortcut = $shell.CreateShortcut($record.path)
    if ($shortcut.TargetPath -eq $wscriptExe -and $shortcut.Arguments -ceq $record.installedArguments) {
        if (-not (Test-Path -LiteralPath $record.backup)) { throw ('Отсутствует резервная копия: ' + $record.backup) }
        $backupHashProperty = $record.PSObject.Properties['backupSha256']
        if ($backupHashProperty) {
            $expectedBackupHash = [string]$backupHashProperty.Value
            if ($expectedBackupHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'BACKUP_HASH_INVALID: Некорректная контрольная сумма резервной копии. Изменения не выполнены.' }
            $actualBackupHash = Get-BackupSha256 $record.backup
            if ($actualBackupHash -ine $expectedBackupHash) { throw 'BACKUP_HASH_MISMATCH: Резервная копия ярлыка изменена. Изменения не выполнены.' }
        }
        $original = $shell.CreateShortcut($record.backup)
        try {
            $installedHash = $record.PSObject.Properties['installedSha256']
            if ($installedHash) {
                $exact = ([string]$installedHash.Value -match '^[a-fA-F0-9]{64}$' -and (Get-BackupSha256 $record.path) -ieq $installedHash.Value)
            } else {
                # Older records have no installed byte snapshot. Preserve metadata
                # edits while retaining exact rollback for their unchanged links.
                $defaultIcon = if ($config.appExe) { $config.appExe + ',0' } else { '' }
                $exact = Test-YandexShortcutMetadata $shortcut $original $defaultIcon
            }
            $restore += [pscustomobject]@{ record = $record; exact = $exact; target = $original.TargetPath; arguments = $original.Arguments }
        } finally { $original.Dispose() }
        Write-Host ('Восстановить ярлык: ' + $record.path)
    } else { Write-Host ('Ярлык изменён отдельно и будет сохранён: ' + $record.path) }
}
if ($DryRun) { Write-Host 'Проверка завершена. Ничего не изменено.'; return }
$before = @{}
foreach ($entry in $restore) {
    Assert-YandexFileWritable $entry.record.path
    $before[$entry.record.path] = [IO.File]::ReadAllBytes($entry.record.path)
}
Assert-YandexFileWritable $configPath
$configBefore = [IO.File]::ReadAllBytes($configPath)
$lock = Join-Path $installRoot 'state\button-helper.json'
$lockText = Read-HelperLockText $lock
if ($null -ne $lockText) {
    $owner = $lockText | ConvertFrom-Json
    if ([string]$owner.pid -notmatch '^\d+$' -or -not $owner.instance -or -not $owner.script) { throw 'Некорректный файл состояния помощника.' }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($owner.pid)"
    if ($process) {
        $helper = Join-Path $config.bundleDir 'ym-button-helper.mjs'
        if ($process.Name -ne 'node.exe' -or [IO.Path]::GetFullPath($owner.script) -ne [IO.Path]::GetFullPath($helper) -or $process.CommandLine -notmatch ('(?:^|\s)"?' + [regex]::Escape($helper) + '"?(?:\s|$)')) { throw 'Не удалось подтвердить владельца помощника. Процесс не изменён.' }
        @{ instance=$owner.instance } | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $installRoot 'state\button-helper-stop.json') -Encoding UTF8
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (Test-Path -LiteralPath $lock) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Дождитесь окончания скачивания и повторите удаление. Скачивание не прервано.' }
            Start-Sleep -Milliseconds 200
        }
    }
}
$changed = @()
try {
    foreach ($entry in $restore) {
        $changed += $entry.record.path
        if ($entry.exact) { Copy-Item -LiteralPath $entry.record.backup -Destination $entry.record.path -Force }
        else {
            $current = $shell.CreateShortcut($entry.record.path)
            try { $current.TargetPath = $entry.target; $current.Arguments = $entry.arguments; $current.Save() }
            finally { $current.Dispose() }
        }
    }
    $config.enabled = $false
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
} catch {
    $failure = $_
    $rollbackErrors = @()
    foreach ($path in $changed) {
        try { [IO.File]::WriteAllBytes($path, $before[$path]) }
        catch { $rollbackErrors += ($path + ': ' + $_.Exception.Message) }
    }
    try { [IO.File]::WriteAllBytes($configPath, $configBefore) }
    catch { $rollbackErrors += ($configPath + ': ' + $_.Exception.Message) }
    if ($rollbackErrors.Count) { throw ($failure.Exception.Message + ' Rollback could not restore: ' + ($rollbackErrors -join '; ')) }
    throw $failure
}
Write-Host 'Обычные ярлыки восстановлены. История, скачанные треки, сессия и резервные копии сохранены.'
} finally {
    if ($ownsLifecycleMutex) { $lifecycleMutex.ReleaseMutex() }
    $lifecycleMutex.Dispose()
    if ($ownsSetupMutex) { $setupMutex.ReleaseMutex() }
    $setupMutex.Dispose()
}
