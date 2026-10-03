# The app's own identity on the taskbar (ARCHITECTURE -> Main window): one AppUserModelID on its
# window and on its Start-menu shortcut. Without it the window takes the identity of the
# PowerShell that hosts it - an MSIX package's, with that package's icon -; with it, the taskbar
# shows the app's icon and name, and pinning the window pins the shortcut, which starts the app
# through its task (docs/AT-COMMANDS.md section 11.2).

# CompanyName.ProductName[.SubProduct], no blanks, at most 128 characters; development mode has its
# own, beside the real app.
$script:AppUserModelId = 'FibocomFm350Gl.WindowsGui'
$script:SimulatedAppUserModelId = 'FibocomFm350Gl.WindowsGui.Simulated'

# A window's and a shortcut's System.AppUserModel.ID, through their property store.
if (-not ('FibocomFm350.AppIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace FibocomFm350
{
    public static class AppIdentity
    {
        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore
        {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PropertyKey
        {
            public Guid FormatId;
            public uint PropertyId;
        }

        // PROPVARIANT, 24 bytes on x64: the type, three reserved words, then the value.
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropVariant
        {
            [FieldOffset(0)] public ushort Type;
            [FieldOffset(8)] public IntPtr Pointer;
        }

        private const ushort VtLpwstr = 31;

        [DllImport("shell32.dll")]
        private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);

        private static PropertyKey IdKey()
        {
            PropertyKey key = new PropertyKey();
            key.FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
            key.PropertyId = 5;
            return key;
        }

        private static IPropertyStore WindowStore(IntPtr window)
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref iid, out store));
            return store;
        }

        // Sets a window's AppUserModelID.
        public static void SetWindowId(IntPtr window, string id)
        {
            IPropertyStore store = WindowStore(window);
            try { Write(store, id); }
            finally { Marshal.ReleaseComObject(store); }
        }

        // Removes it, as it must be before the window closes: the property set to VT_EMPTY. (A
        // method of its own: PowerShell passes $null to a string parameter as an empty string,
        // which Windows refuses as an AppUserModelID.)
        public static void RemoveWindowId(IntPtr window)
        {
            IPropertyStore store = WindowStore(window);
            try
            {
                PropertyKey key = IdKey();
                PropVariant empty = new PropVariant();
                Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref empty));
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static string GetWindowId(IntPtr window)
        {
            IPropertyStore store = WindowStore(window);
            try { return Read(store); }
            finally { Marshal.ReleaseComObject(store); }
        }

        // Sets a shortcut file's AppUserModelID, and saves the file.
        public static void SetShortcutId(string path, string id)
        {
            object link = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
            try
            {
                IPersistFile file = (IPersistFile)link;
                file.Load(path, 2);
                IPropertyStore store = (IPropertyStore)link;
                Write(store, id);
                Marshal.ThrowExceptionForHR(store.Commit());
                file.Save(path, true);
            }
            finally { Marshal.ReleaseComObject(link); }
        }

        public static string GetShortcutId(string path)
        {
            object link = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
            try
            {
                ((IPersistFile)link).Load(path, 0);
                return Read((IPropertyStore)link);
            }
            finally { Marshal.ReleaseComObject(link); }
        }

        private static void Write(IPropertyStore store, string id)
        {
            PropertyKey key = IdKey();
            PropVariant value = new PropVariant();
            value.Type = VtLpwstr;
            value.Pointer = Marshal.StringToCoTaskMemUni(id);
            try { Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value)); }
            finally { Marshal.FreeCoTaskMem(value.Pointer); }
        }

        private static string Read(IPropertyStore store)
        {
            PropertyKey key = IdKey();
            PropVariant value;
            Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
            try { return value.Type == VtLpwstr ? Marshal.PtrToStringUni(value.Pointer) : null; }
            finally { PropVariantClear(ref value); }
        }
    }
}
'@
}

function Set-AppWindowIdentity {
    # Gives a WPF window the app's AppUserModelID -Id, before it is shown; with -Remove, takes it
    # off again, as it must be before the window closes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes a property of the app''s own window; changes no system state.')]
    param([System.Windows.Window] $Window, [string] $Id, [switch] $Remove)

    $handle = [System.Windows.Interop.WindowInteropHelper]::new($Window).EnsureHandle()
    if ($Remove) {
        [FibocomFm350.AppIdentity]::RemoveWindowId($handle)
    }
    else {
        [FibocomFm350.AppIdentity]::SetWindowId($handle, $Id)
    }
}

function Set-AppShortcutIdentity {
    <#
    .SYNOPSIS
        Gives a shortcut the app's AppUserModelID, the one its window carries.
    .DESCRIPTION
        For the Start-menu shortcut: the taskbar then shows the window with the shortcut's icon
        and name, and pinning the window pins the shortcut.
    .EXAMPLE
        Set-AppShortcutIdentity -Path $layout.Shortcut
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($PSCmdlet.ShouldProcess($Path, 'Give the shortcut the app''s taskbar identity')) {
        [FibocomFm350.AppIdentity]::SetShortcutId([System.IO.Path]::GetFullPath($Path), $script:AppUserModelId)
    }
}
