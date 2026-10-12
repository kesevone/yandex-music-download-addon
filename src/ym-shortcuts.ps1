# WSH shortcuts reject some Unicode targets on Windows with an ANSI code page.
# Use the documented wide-character Shell Link API for every path read and write.
if (-not ('YandexMusicAddon.ShortcutShell' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace YandexMusicAddon {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class NativeShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path,
                     int count, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int count);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int count);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int count);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string value);
        void GetHotkey(out short value);
        void SetHotkey(short value);
        void GetShowCmd(out int value);
        void SetShowCmd(int value);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, int count, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string value, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string value, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string value);
    }

    [ComImport, Guid("0000010B-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPersistFileW {
        void GetClassID(out Guid classID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string file, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string file);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string file);
    }

    public sealed class ShortcutShell {
        public Shortcut CreateShortcut(string path) { return new Shortcut(path); }
    }

    public sealed class Shortcut : IDisposable {
        private object native;
        private IShellLinkW link;
        private IPersistFileW file;
        private readonly string path;
        private const int BufferSize = 32768;

        internal Shortcut(string shortcutPath) {
            path = Path.GetFullPath(shortcutPath);
            if (!string.Equals(Path.GetExtension(path), ".lnk", StringComparison.OrdinalIgnoreCase)) {
                throw new ArgumentException("Only .lnk shortcuts are supported.", "shortcutPath");
            }
            native = new NativeShellLink();
            try {
                link = (IShellLinkW)native;
                file = (IPersistFileW)native;
                if (File.Exists(path)) { file.Load(path, 0); }
            } catch { Dispose(); throw; }
        }

        private void EnsureOpen() {
            if (native == null) { throw new ObjectDisposedException("Shortcut"); }
        }

        public string TargetPath {
            get {
                EnsureOpen();
                var value = new StringBuilder(BufferSize);
                // SLGP_RAWPATH avoids resolving/searching the target. Expand only
                // local environment variables before installer identity checks.
                link.GetPath(value, value.Capacity, IntPtr.Zero, 4);
                return Environment.ExpandEnvironmentVariables(value.ToString());
            }
            set {
                EnsureOpen();
                // Shell Link automatically changes a working directory equal
                // to the old executable's directory when SetPath is called.
                // A launch hook must retain the original working directory.
                var working = new StringBuilder(BufferSize);
                link.GetWorkingDirectory(working, working.Capacity);
                link.SetPath(value ?? "");
                link.SetWorkingDirectory(working.ToString());
            }
        }

        public string Arguments {
            get {
                EnsureOpen();
                var value = new StringBuilder(BufferSize);
                link.GetArguments(value, value.Capacity);
                return value.ToString();
            }
            set { EnsureOpen(); link.SetArguments(value ?? ""); }
        }

        public string WorkingDirectory {
            get {
                EnsureOpen();
                var value = new StringBuilder(BufferSize);
                link.GetWorkingDirectory(value, value.Capacity);
                return value.ToString();
            }
            set { EnsureOpen(); link.SetWorkingDirectory(value ?? ""); }
        }

        public short Hotkey {
            get { EnsureOpen(); short value; link.GetHotkey(out value); return value; }
            set { EnsureOpen(); link.SetHotkey(value); }
        }

        public int WindowStyle {
            get { EnsureOpen(); int value; link.GetShowCmd(out value); return value; }
            set { EnsureOpen(); link.SetShowCmd(value); }
        }

        public string Description {
            get {
                EnsureOpen(); var value = new StringBuilder(BufferSize);
                link.GetDescription(value, value.Capacity); return value.ToString();
            }
            set { EnsureOpen(); link.SetDescription(value ?? ""); }
        }

        public string IconLocation {
            get {
                EnsureOpen();
                var value = new StringBuilder(BufferSize);
                int index;
                link.GetIconLocation(value, value.Capacity, out index);
                if (value.Length == 0) { return ""; }
                return value.ToString() + "," + index.ToString(CultureInfo.InvariantCulture);
            }
            set {
                EnsureOpen();
                string icon = value ?? "";
                int index = 0;
                int separator = icon.LastIndexOf(',');
                int parsed;
                if (separator >= 0 && int.TryParse(icon.Substring(separator + 1).Trim(),
                        NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)) {
                    index = parsed;
                    icon = icon.Substring(0, separator);
                }
                link.SetIconLocation(icon.Trim().Trim('"'), index);
            }
        }

        public void Save() {
            EnsureOpen();
            // Load and modify the existing link object, retaining unrelated
            // metadata. Do not call Resolve: it may search or prompt the user.
            file.Save(path, true);
        }

        public void Dispose() {
            object owned = native;
            native = null;
            link = null;
            file = null;
            if (owned != null && Marshal.IsComObject(owned)) { Marshal.FinalReleaseComObject(owned); }
        }
    }
}
'@
}

function New-YandexShortcutShell {
    New-Object YandexMusicAddon.ShortcutShell
}

function New-YandexLifecycleMutex([string]$Root, [string]$Kind = 'Lifecycle') {
    $canonical = [IO.Path]::GetFullPath($Root).TrimEnd('\').ToLowerInvariant()
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
    New-Object Threading.Mutex($false, ('Local\YandexMusicAddon.' + $Kind + '.' + $key))
}

function Enter-YandexLifecycleMutex($Mutex, [int]$Timeout = 30000) {
    try { return $Mutex.WaitOne($Timeout) }
    catch [Threading.AbandonedMutexException] { return $true }
}

function Assert-YandexFileWritable([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReadOnly) -ne 0) { throw ('File is read-only: ' + $Path) }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    $stream.Dispose()
}

function Complete-YandexAtomicFile([string]$Temporary, [string]$Destination) {
    if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($Temporary, $Destination, [NullString]::Value) }
    else { [IO.File]::Move($Temporary, $Destination) }
}

function Copy-YandexAtomicFile([string]$Source, [string]$Destination) {
    $temporary = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.new'
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        Complete-YandexAtomicFile $temporary $Destination
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Write-YandexAtomicBytes([string]$Destination, [byte[]]$Bytes) {
    $temporary = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.new'
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        Complete-YandexAtomicFile $temporary $Destination
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Test-YandexShortcutMetadata($Current, $Original, [string]$DefaultIcon) {
    $icon = $Original.IconLocation
    if (-not $icon) { $icon = $DefaultIcon }
    return ($Current.IconLocation -eq $icon -and $Current.WorkingDirectory -eq $Original.WorkingDirectory -and
        $Current.Hotkey -eq $Original.Hotkey -and $Current.WindowStyle -eq $Original.WindowStyle -and
        $Current.Description -eq $Original.Description)
}
