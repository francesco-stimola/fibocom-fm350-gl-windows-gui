# The modem's vendor functions on Windows' own WinUSB driver: the AT function's interface found and
# opened, a function put on WinUSB and given back to its best driver, a COM port tried for another
# program holding it. Facts and sources: docs/AT-COMMANDS.md section 1.2; design:
# docs/ARCHITECTURE.md -> USB functions.
#
# The Windows calls are in C#, compiled once per process by Add-Type, in memory: no DLL is built or
# shipped. Each returns Windows' own error codes; what they mean is decided in PowerShell. Every
# handle is a SafeHandle, released on the error path too. No size is assumed: structure sizes come
# from the marshaller, pointers are IntPtr - the same code runs on x64 and Arm64.

# The device interface class the app gives the AT function (DeviceInterfaceGUIDs): its own, so
# that it finds the interface it put there, and no other program's.
$script:AppInterfaceGuid = '{4FDE9624-2286-4DC0-9D07-601A3922581A}'

# Windows' own WinUSB INF, its generic model's hardware ID - never its name, which is localized -
# and the class it installs devices in (AT-COMMANDS section 1.2).
$script:WinUsbInfName = 'winusb.inf'
$script:WinUsbModelId = 'USB\MS_COMP_WINUSB'
$script:UsbDeviceClassGuid = '{88BAE032-5A81-49F0-BC3D-A4FF138216D6}'

# Windows' error codes the app tells apart. A port another program holds answers an exclusive open
# with one of HeldErrors: MediaTek's serial driver with ERROR_BUSY, WinUSB with ERROR_ACCESS_DENIED
# (AT-COMMANDS sections 1.2 and 2).
$script:Win32Errors = @{
    AccessDenied     = 5
    SharingViolation = 32
    Busy             = 170
}
$script:HeldErrors = @(5, 32, 170)

# How long a driver installation may take before it is given up, in ms: as pnputil's (M6).
$script:UsbBindingTimeoutMs = 300000

if (-not ('FibocomFm350.WinUsbInterface' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace FibocomFm350
{
    // One pipe of a USB interface, as WinUSB describes it.
    public sealed class UsbPipe
    {
        // The endpoint's address: bit 7 set for IN.
        public byte Id;
        // USBD_PIPE_TYPE: 0 control, 1 isochronous, 2 bulk, 3 interrupt.
        public int Type;
        public int MaximumPacketSize;
    }

    // A transfer's outcome: Windows' error code (0: none) and the bytes moved.
    public sealed class UsbTransfer
    {
        public int Error;
        public int Count;
    }

    // A driver installation's outcome: done, a restart needed to finish it, or the step that
    // failed with Windows' error code.
    public sealed class UsbBindingResult
    {
        public bool Done;
        public bool NeedReboot;
        public string Step;
        public int Error;
    }

    internal sealed class WinUsbHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public WinUsbHandle() : base(true) { }

        protected override bool ReleaseHandle()
        {
            return Native.WinUsb_Free(handle);
        }
    }

    internal static class Native
    {
        public const uint GenericRead = 0x80000000;
        public const uint GenericWrite = 0x40000000;
        public const uint FileShareRead = 0x1;
        public const uint FileShareWrite = 0x2;
        public const uint OpenExisting = 3;
        public const uint FileAttributeNormal = 0x80;
        public const uint FileFlagOverlapped = 0x40000000;

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct InterfaceDescriptor
        {
            public byte Length;
            public byte DescriptorType;
            public byte InterfaceNumber;
            public byte AlternateSetting;
            public byte NumEndpoints;
            public byte InterfaceClass;
            public byte InterfaceSubClass;
            public byte InterfaceProtocol;
            public byte Interface;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PipeInformation
        {
            public int PipeType;
            public byte PipeId;
            public ushort MaximumPacketSize;
            public byte Interval;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("winusb.dll", SetLastError = true)]
        public static extern bool WinUsb_Initialize(SafeFileHandle device, out WinUsbHandle handle);

        [DllImport("winusb.dll", SetLastError = true)]
        public static extern bool WinUsb_Free(IntPtr handle);

        [DllImport("winusb.dll", SetLastError = true)]
        public static extern bool WinUsb_QueryInterfaceSettings(WinUsbHandle handle, byte alternate, out InterfaceDescriptor descriptor);

        [DllImport("winusb.dll", SetLastError = true)]
        public static extern bool WinUsb_QueryPipe(WinUsbHandle handle, byte alternate, byte index, out PipeInformation pipe);

        [DllImport("winusb.dll", SetLastError = true)]
        public static extern bool WinUsb_SetPipePolicy(WinUsbHandle handle, byte pipe, uint policy, uint length, ref uint value);

        [DllImport("winusb.dll", SetLastError = true)]
        public static extern bool WinUsb_ReadPipe(WinUsbHandle handle, byte pipe, byte[] buffer, uint length, out uint transferred, IntPtr overlapped);

        [DllImport("winusb.dll", SetLastError = true)]
        public static extern bool WinUsb_WritePipe(WinUsbHandle handle, byte pipe, byte[] buffer, uint length, out uint transferred, IntPtr overlapped);

        public const uint CmListPresent = 0;
        public const int CrSuccess = 0;
        public const int CrNoSuchDevinst = 0x0D;
        public const int CrBufferSmall = 0x1A;

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        public static extern int CM_Get_Device_Interface_List_SizeW(out uint length, ref Guid iface, string deviceId, uint flags);

        [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
        public static extern int CM_Get_Device_Interface_ListW(ref Guid iface, string deviceId, char[] buffer, uint length, uint flags);

        public static readonly IntPtr InvalidHandle = new IntPtr(-1);
        public const uint DicsFlagGlobal = 1;
        public const uint DiregDev = 1;
        public const uint SpdrpClassGuid = 8;
        public const uint SpditClassDriver = 1;
        public const uint DiEnumSingleInf = 0x00010000;
        public const uint DiFlagsExAllowExcludedDrivers = 0x00000800;
        public const uint DiidFlagNoFinishInstallUi = 0x2;
        public const uint DiidFlagInstallNullDriver = 0x4;
        public const int ErrorNoMoreItems = 259;
        public const int ErrorInsufficientBuffer = 122;
        public const int ErrorNotFound = 1168;

        [StructLayout(LayoutKind.Sequential)]
        public struct DevInfoData
        {
            public uint Size;
            public Guid ClassGuid;
            public uint DevInst;
            public IntPtr Reserved;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DevInstallParams
        {
            public uint Size;
            public uint Flags;
            public uint FlagsEx;
            public IntPtr ParentWindow;
            public IntPtr InstallMessageHandler;
            public IntPtr InstallMessageHandlerContext;
            public IntPtr FileQueue;
            public IntPtr ClassInstallReserved;
            public uint Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string DriverPath;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DrvInfoData
        {
            public uint Size;
            public uint DriverType;
            public IntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string Description;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string ManufacturerName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string ProviderName;
            public System.Runtime.InteropServices.ComTypes.FILETIME DriverDate;
            public ulong DriverVersion;
        }

        // SP_DRVINFO_DETAIL_DATA_W up to its first hardware ID character: what cbSize must say.
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DrvInfoDetailHead
        {
            public uint Size;
            public System.Runtime.InteropServices.ComTypes.FILETIME InfDate;
            public uint CompatIdsOffset;
            public uint CompatIdsLength;
            public IntPtr Reserved;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string SectionName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string InfFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string DriverDescription;
            public char HardwareId;
        }

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr classGuid, IntPtr parent);

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetupDiOpenDeviceInfoW(IntPtr set, string instanceId, IntPtr parent, uint flags, ref DevInfoData device);

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern IntPtr SetupDiCreateDevRegKeyW(IntPtr set, ref DevInfoData device, uint scope, uint profile, uint keyType, IntPtr inf, IntPtr section);

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiGetDeviceRegistryPropertyW(IntPtr set, ref DevInfoData device, uint property, out uint type, byte[] buffer, uint size, out uint required);

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr set, ref DevInfoData device, uint property, byte[] buffer, uint size);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetupDiGetDeviceInstallParamsW(IntPtr set, ref DevInfoData device, ref DevInstallParams parameters);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetupDiSetDeviceInstallParamsW(IntPtr set, ref DevInfoData device, ref DevInstallParams parameters);

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiBuildDriverInfoList(IntPtr set, ref DevInfoData device, uint type);

        [DllImport("setupapi.dll", SetLastError = true)]
        public static extern bool SetupDiDestroyDriverInfoList(IntPtr set, ref DevInfoData device, uint type);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetupDiEnumDriverInfoW(IntPtr set, ref DevInfoData device, uint type, uint index, ref DrvInfoData driver);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetupDiGetDriverInfoDetailW(IntPtr set, ref DevInfoData device, ref DrvInfoData driver, IntPtr detail, uint size, out uint required);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool SetupDiSetSelectedDriverW(IntPtr set, ref DevInfoData device, ref DrvInfoData driver);

        [DllImport("newdev.dll", SetLastError = true)]
        public static extern bool DiInstallDevice(IntPtr parent, IntPtr set, ref DevInfoData device, ref DrvInfoData driver, uint flags, out bool needReboot);

        [DllImport("newdev.dll", EntryPoint = "DiInstallDevice", SetLastError = true)]
        public static extern bool DiInstallBestDevice(IntPtr parent, IntPtr set, ref DevInfoData device, IntPtr driver, uint flags, out bool needReboot);
    }

    // One USB interface opened through WinUSB: its descriptor's class, its pipes, and transfers
    // on them. Disposing releases both handles, once.
    public sealed class WinUsbInterface : IDisposable
    {
        private SafeFileHandle device;
        private WinUsbHandle usb;

        public byte InterfaceNumber { get; private set; }
        public byte InterfaceClass { get; private set; }
        public byte InterfaceSubClass { get; private set; }
        public byte InterfaceProtocol { get; private set; }
        public UsbPipe[] Pipes { get; private set; }

        private WinUsbInterface() { }

        // Opens the interface at a device interface path (Get-WinUsbInterfacePath). Throws a
        // Win32Exception with Windows' error: another program holding it among them.
        public static WinUsbInterface Open(string path)
        {
            var opened = new WinUsbInterface();
            try
            {
                opened.device = Native.CreateFileW(path, Native.GenericRead | Native.GenericWrite, Native.FileShareRead | Native.FileShareWrite,
                    IntPtr.Zero, Native.OpenExisting, Native.FileAttributeNormal | Native.FileFlagOverlapped, IntPtr.Zero);
                if (opened.device.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                WinUsbHandle usb;
                if (!Native.WinUsb_Initialize(opened.device, out usb))
                {
                    int error = Marshal.GetLastWin32Error();
                    usb.Dispose();
                    throw new Win32Exception(error);
                }
                opened.usb = usb;
                Native.InterfaceDescriptor descriptor;
                if (!Native.WinUsb_QueryInterfaceSettings(usb, 0, out descriptor))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                opened.InterfaceNumber = descriptor.InterfaceNumber;
                opened.InterfaceClass = descriptor.InterfaceClass;
                opened.InterfaceSubClass = descriptor.InterfaceSubClass;
                opened.InterfaceProtocol = descriptor.InterfaceProtocol;
                var pipes = new List<UsbPipe>();
                for (byte index = 0; index < descriptor.NumEndpoints; index++)
                {
                    Native.PipeInformation pipe;
                    if (!Native.WinUsb_QueryPipe(usb, 0, index, out pipe))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    pipes.Add(new UsbPipe { Id = pipe.PipeId, Type = pipe.PipeType, MaximumPacketSize = pipe.MaximumPacketSize });
                }
                opened.Pipes = pipes.ToArray();
                return opened;
            }
            catch
            {
                opened.Dispose();
                throw;
            }
        }

        // A transfer on the pipe gives up after this many milliseconds (PIPE_TRANSFER_TIMEOUT).
        // Returns Windows' error code, 0 for success.
        public int SetTimeout(byte pipe, uint milliseconds)
        {
            uint value = milliseconds;
            return Native.WinUsb_SetPipePolicy(usb, pipe, 0x03, 4, ref value) ? 0 : Marshal.GetLastWin32Error();
        }

        // Reads into the buffer: what one transfer brings, within the pipe's timeout.
        public UsbTransfer Read(byte pipe, byte[] buffer)
        {
            uint count;
            if (!Native.WinUsb_ReadPipe(usb, pipe, buffer, (uint)buffer.Length, out count, IntPtr.Zero))
            {
                return new UsbTransfer { Error = Marshal.GetLastWin32Error(), Count = 0 };
            }
            return new UsbTransfer { Error = 0, Count = (int)count };
        }

        // Writes the bytes from offset, as one transfer, within the pipe's timeout.
        public UsbTransfer Write(byte pipe, byte[] data, int offset, int length)
        {
            var part = new byte[length];
            Array.Copy(data, offset, part, 0, length);
            uint count;
            if (!Native.WinUsb_WritePipe(usb, pipe, part, (uint)length, out count, IntPtr.Zero))
            {
                return new UsbTransfer { Error = Marshal.GetLastWin32Error(), Count = (int)count };
            }
            return new UsbTransfer { Error = 0, Count = (int)count };
        }

        public void Dispose()
        {
            if (usb != null)
            {
                usb.Dispose();
                usb = null;
            }
            if (device != null)
            {
                device.Dispose();
                device = null;
            }
        }
    }

    public static class UsbDevices
    {
        // The present device interfaces of a device in an interface class: their paths. None
        // when the device is not there. Throws on another error of the configuration manager.
        public static string[] GetInterfacePaths(Guid iface, string instanceId)
        {
            for (int attempt = 0; attempt < 5; attempt++)
            {
                uint length;
                int result = Native.CM_Get_Device_Interface_List_SizeW(out length, ref iface, instanceId, Native.CmListPresent);
                if (result == Native.CrNoSuchDevinst)
                {
                    return new string[0];
                }
                if (result != Native.CrSuccess)
                {
                    throw new InvalidOperationException("CM_Get_Device_Interface_List_Size: CONFIGRET " + result);
                }
                var buffer = new char[length];
                result = Native.CM_Get_Device_Interface_ListW(ref iface, instanceId, buffer, length, Native.CmListPresent);
                if (result == Native.CrBufferSmall)
                {
                    // An interface arrived between the two calls.
                    continue;
                }
                if (result == Native.CrNoSuchDevinst)
                {
                    return new string[0];
                }
                if (result != Native.CrSuccess)
                {
                    throw new InvalidOperationException("CM_Get_Device_Interface_List: CONFIGRET " + result);
                }
                var paths = new List<string>();
                foreach (string path in new string(buffer).Split('\0'))
                {
                    if (path.Length > 0)
                    {
                        paths.Add(path);
                    }
                }
                return paths.ToArray();
            }
            throw new InvalidOperationException("CM_Get_Device_Interface_List: the list kept growing");
        }

        // Opens a COM port or a device interface exclusively and closes it at once, nothing read or
        // written: 0 when it could be opened, else Windows' error - ERROR_BUSY, ERROR_ACCESS_DENIED
        // or ERROR_SHARING_VIOLATION: another program holds it.
        public static int TryPath(string path)
        {
            using (SafeFileHandle port = Native.CreateFileW(path, Native.GenericRead | Native.GenericWrite, 0, IntPtr.Zero,
                Native.OpenExisting, 0, IntPtr.Zero))
            {
                return port.IsInvalid ? Marshal.GetLastWin32Error() : 0;
            }
        }

        public static int TryComPort(string portName)
        {
            return TryPath(@"\\.\" + portName);
        }
    }

    // A function of the modem put on WinUSB, or given back to its best driver, as Device Manager
    // does it. Administrator rights; a 64-bit process on 64-bit Windows.
    public static class UsbDriverBinding
    {
        private const string InterfaceGuidsValue = "DeviceInterfaceGUIDs";

        private static UsbBindingResult Failed(string step, int error)
        {
            return new UsbBindingResult { Done = false, Step = step, Error = error };
        }

        private static void RefuseNetworkFunction(string instanceId)
        {
            // The network function is Windows' RNDIS: never touched (ARCHITECTURE -> USB functions).
            if (instanceId.IndexOf("&MI_00", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                throw new ArgumentException("The modem's network function is never given another driver.", "instanceId");
            }
        }

        // Adds or removes the interface class in the device's DeviceInterfaceGUIDs, keeping any
        // other there. Returns whether the value changed.
        private static bool ChangeInterfaceGuid(IntPtr set, ref Native.DevInfoData device, string guid, bool add)
        {
            IntPtr key = Native.SetupDiCreateDevRegKeyW(set, ref device, Native.DicsFlagGlobal, 0, Native.DiregDev, IntPtr.Zero, IntPtr.Zero);
            if (key == Native.InvalidHandle)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            using (var handle = new SafeRegistryHandle(key, true))
            using (RegistryKey parameters = RegistryKey.FromHandle(handle))
            {
                var guids = new List<string>();
                var existing = parameters.GetValue(InterfaceGuidsValue) as string[];
                if (existing != null)
                {
                    guids.AddRange(existing);
                }
                int found = guids.FindIndex(g => string.Equals(g.Trim(), guid, StringComparison.OrdinalIgnoreCase));
                if (add == (found >= 0))
                {
                    return false;
                }
                if (add)
                {
                    guids.Add(guid);
                }
                else
                {
                    guids.RemoveAt(found);
                }
                if (guids.Count == 0)
                {
                    parameters.DeleteValue(InterfaceGuidsValue, false);
                }
                else
                {
                    parameters.SetValue(InterfaceGuidsValue, guids.ToArray(), RegistryValueKind.MultiString);
                }
                return true;
            }
        }

        private static string ReadClassGuid(IntPtr set, ref Native.DevInfoData device)
        {
            var buffer = new byte[256];
            uint type;
            uint required;
            if (!Native.SetupDiGetDeviceRegistryPropertyW(set, ref device, Native.SpdrpClassGuid, out type, buffer, (uint)buffer.Length, out required))
            {
                // A device without a driver has no class.
                return null;
            }
            return Encoding.Unicode.GetString(buffer, 0, (int)required).TrimEnd('\0');
        }

        // The hardware ID of a driver in the list, or null.
        private static string ReadModelId(IntPtr set, ref Native.DevInfoData device, ref Native.DrvInfoData driver)
        {
            int headSize = Marshal.SizeOf(typeof(Native.DrvInfoDetailHead));
            int idOffset = Marshal.OffsetOf(typeof(Native.DrvInfoDetailHead), "HardwareId").ToInt32();
            uint size = 8192;
            for (int attempt = 0; attempt < 2; attempt++)
            {
                IntPtr detail = Marshal.AllocHGlobal((int)size);
                try
                {
                    Marshal.WriteInt32(detail, headSize);
                    uint required;
                    if (!Native.SetupDiGetDriverInfoDetailW(set, ref device, ref driver, detail, size, out required))
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == Native.ErrorInsufficientBuffer && required > size)
                        {
                            size = required;
                            continue;
                        }
                        return null;
                    }
                    int compatOffset = Marshal.ReadInt32(detail, Marshal.OffsetOf(typeof(Native.DrvInfoDetailHead), "CompatIdsOffset").ToInt32());
                    return compatOffset > 1 ? Marshal.PtrToStringUni(IntPtr.Add(detail, idOffset)) : null;
                }
                finally
                {
                    Marshal.FreeHGlobal(detail);
                }
            }
            return null;
        }

        // Gives the device back to the driver Windows ranks best in its driver store - or none,
        // when none matches: a null driver, as if Windows had found no driver for it.
        private static UsbBindingResult InstallBest(string instanceId)
        {
            IntPtr set = Native.SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (set == Native.InvalidHandle)
            {
                return Failed("List", Marshal.GetLastWin32Error());
            }
            try
            {
                var device = new Native.DevInfoData { Size = (uint)Marshal.SizeOf(typeof(Native.DevInfoData)) };
                if (!Native.SetupDiOpenDeviceInfoW(set, instanceId, IntPtr.Zero, 0, ref device))
                {
                    return Failed("Open", Marshal.GetLastWin32Error());
                }
                bool reboot;
                if (Native.DiInstallBestDevice(IntPtr.Zero, set, ref device, IntPtr.Zero, Native.DiidFlagNoFinishInstallUi, out reboot))
                {
                    return new UsbBindingResult { Done = true, NeedReboot = reboot, Step = "Best" };
                }
                int best = Marshal.GetLastWin32Error();
                if (best == 5)
                {
                    return Failed("Best", best);
                }
                if (Native.DiInstallBestDevice(IntPtr.Zero, set, ref device, IntPtr.Zero, Native.DiidFlagInstallNullDriver, out reboot))
                {
                    return new UsbBindingResult { Done = true, NeedReboot = reboot, Step = "Null", Error = best };
                }
                return Failed("Null", Marshal.GetLastWin32Error());
            }
            finally
            {
                Native.SetupDiDestroyDeviceInfoList(set);
            }
        }

        // Puts a function of the modem on WinUSB: interfaceGuid, when given, written in its
        // DeviceInterfaceGUIDs first; its class set to infPath's; the INF's model with the hardware
        // ID modelId selected and installed, no window. A failure after the class changed gives
        // the device back to its best driver, and takes the interface class back out.
        public static UsbBindingResult InstallWinUsb(string instanceId, string infPath, string modelId, string classGuid, string interfaceGuid)
        {
            RefuseNetworkFunction(instanceId);
            IntPtr set = Native.SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (set == Native.InvalidHandle)
            {
                return Failed("List", Marshal.GetLastWin32Error());
            }
            bool guidAdded = false;
            bool classChanged = false;
            UsbBindingResult result = null;
            var device = new Native.DevInfoData { Size = (uint)Marshal.SizeOf(typeof(Native.DevInfoData)) };
            try
            {
                if (!Native.SetupDiOpenDeviceInfoW(set, instanceId, IntPtr.Zero, 0, ref device))
                {
                    return result = Failed("Open", Marshal.GetLastWin32Error());
                }
                if (!string.IsNullOrEmpty(interfaceGuid))
                {
                    try
                    {
                        guidAdded = ChangeInterfaceGuid(set, ref device, interfaceGuid, true);
                    }
                    catch (Win32Exception e)
                    {
                        return result = Failed("InterfaceGuid", e.NativeErrorCode);
                    }
                    catch (Exception e)
                    {
                        return result = Failed("InterfaceGuid", Marshal.GetHRForException(e));
                    }
                }
                string current = ReadClassGuid(set, ref device);
                if (!string.Equals(current, classGuid, StringComparison.OrdinalIgnoreCase))
                {
                    byte[] value = Encoding.Unicode.GetBytes(classGuid + "\0");
                    if (!Native.SetupDiSetDeviceRegistryPropertyW(set, ref device, Native.SpdrpClassGuid, value, (uint)value.Length))
                    {
                        return result = Failed("Class", Marshal.GetLastWin32Error());
                    }
                    classChanged = true;
                }
                var parameters = new Native.DevInstallParams { Size = (uint)Marshal.SizeOf(typeof(Native.DevInstallParams)) };
                if (!Native.SetupDiGetDeviceInstallParamsW(set, ref device, ref parameters))
                {
                    return result = Failed("Parameters", Marshal.GetLastWin32Error());
                }
                parameters.Flags |= Native.DiEnumSingleInf;
                parameters.FlagsEx |= Native.DiFlagsExAllowExcludedDrivers;
                parameters.DriverPath = infPath;
                if (!Native.SetupDiSetDeviceInstallParamsW(set, ref device, ref parameters))
                {
                    return result = Failed("Parameters", Marshal.GetLastWin32Error());
                }
                if (!Native.SetupDiBuildDriverInfoList(set, ref device, Native.SpditClassDriver))
                {
                    return result = Failed("DriverList", Marshal.GetLastWin32Error());
                }
                try
                {
                    var driver = new Native.DrvInfoData { Size = (uint)Marshal.SizeOf(typeof(Native.DrvInfoData)) };
                    bool found = false;
                    for (uint index = 0; ; index++)
                    {
                        if (!Native.SetupDiEnumDriverInfoW(set, ref device, Native.SpditClassDriver, index, ref driver))
                        {
                            break;
                        }
                        if (string.Equals(ReadModelId(set, ref device, ref driver), modelId, StringComparison.OrdinalIgnoreCase))
                        {
                            found = true;
                            break;
                        }
                    }
                    if (!found)
                    {
                        return result = Failed("Model", Native.ErrorNotFound);
                    }
                    if (!Native.SetupDiSetSelectedDriverW(set, ref device, ref driver))
                    {
                        return result = Failed("Select", Marshal.GetLastWin32Error());
                    }
                    bool reboot;
                    if (!Native.DiInstallDevice(IntPtr.Zero, set, ref device, ref driver, Native.DiidFlagNoFinishInstallUi, out reboot))
                    {
                        return result = Failed("Install", Marshal.GetLastWin32Error());
                    }
                    return result = new UsbBindingResult { Done = true, NeedReboot = reboot, Step = "Install" };
                }
                finally
                {
                    Native.SetupDiDestroyDriverInfoList(set, ref device, Native.SpditClassDriver);
                }
            }
            finally
            {
                if (result != null && !result.Done && guidAdded)
                {
                    try
                    {
                        ChangeInterfaceGuid(set, ref device, interfaceGuid, false);
                    }
                    catch (Exception)
                    {
                        // The value is harmless on a device not on WinUSB; the failure is the one told.
                    }
                }
                Native.SetupDiDestroyDeviceInfoList(set);
                if (result != null && !result.Done && classChanged)
                {
                    InstallBest(instanceId);
                }
            }
        }

        // Gives a function back to the driver Windows ranks best - none when none matches -, the
        // interface class taken out of its DeviceInterfaceGUIDs first.
        public static UsbBindingResult Restore(string instanceId, string interfaceGuid)
        {
            RefuseNetworkFunction(instanceId);
            if (!string.IsNullOrEmpty(interfaceGuid))
            {
                IntPtr set = Native.SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
                if (set == Native.InvalidHandle)
                {
                    return Failed("List", Marshal.GetLastWin32Error());
                }
                try
                {
                    var device = new Native.DevInfoData { Size = (uint)Marshal.SizeOf(typeof(Native.DevInfoData)) };
                    if (!Native.SetupDiOpenDeviceInfoW(set, instanceId, IntPtr.Zero, 0, ref device))
                    {
                        return Failed("Open", Marshal.GetLastWin32Error());
                    }
                    ChangeInterfaceGuid(set, ref device, interfaceGuid, false);
                }
                catch (Win32Exception e)
                {
                    return Failed("InterfaceGuid", e.NativeErrorCode);
                }
                catch (Exception e)
                {
                    return Failed("InterfaceGuid", Marshal.GetHRForException(e));
                }
                finally
                {
                    Native.SetupDiDestroyDeviceInfoList(set);
                }
            }
            return InstallBest(instanceId);
        }

        // The same, on a thread of the pool: the caller waits for it a second at a time, its
        // heartbeat beating.
        public static Task<UsbBindingResult> StartInstallWinUsb(string instanceId, string infPath, string modelId, string classGuid, string interfaceGuid)
        {
            return Task.Run(() => InstallWinUsb(instanceId, infPath, modelId, classGuid, interfaceGuid));
        }

        public static Task<UsbBindingResult> StartRestore(string instanceId, string interfaceGuid)
        {
            return Task.Run(() => Restore(instanceId, interfaceGuid));
        }
    }
}
'@
}

function Get-WinUsbInterfacePath {
    <#
    .SYNOPSIS
        Returns the device interface path of a function on WinUSB, in the app's interface class.
    .DESCRIPTION
        CM_Get_Device_Interface_List for the function's instance ID and the class the app writes in
        its DeviceInterfaceGUIDs (AT-COMMANDS section 1.2): the path to open it with. Nothing
        when the function has no such interface - not on WinUSB, not given the class, not present.
        Reads only; needs no administrator rights.
    .EXAMPLE
        Get-WinUsbInterfacePath -InstanceId $presence.AtInstanceId
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $InstanceId,

        [string] $InterfaceGuid = $script:AppInterfaceGuid
    )

    [FibocomFm350.UsbDevices]::GetInterfacePaths([guid]$InterfaceGuid, $InstanceId)
}

function Test-Win32Held {
    # Whether Windows' answer to an exclusive open says another program holds the port: pure.
    param([int] $Code)

    $Code -in $script:HeldErrors
}

function Test-UsbFunctionFree {
    <#
    .SYNOPSIS
        Tells whether another program holds one of a function's ports: its COM port, or one of its
        device interfaces.
    .DESCRIPTION
        Before the app gives a function of the modem another driver, the program that holds one of
        its ports, if any, is left alone (decided 2026-10-04): each is opened for an instant,
        exclusively, nothing read or written - its COM port (-PortName), and every present
        interface of each class its DeviceInterfaceGUIDs name (-InterfaceGuid: WinUSB's, the app's
        or another program's). One gone meanwhile is not held. An interface its driver registers
        under a class not named there is not looked at.

        Returns Free ($false when one of them is held), Held ('Port', 'Interface' or $null) and
        Error, Windows' code for the one held (0 otherwise).
    .EXAMPLE
        (Test-UsbFunctionFree -InstanceId $function.InstanceId -PortName $function.PortName -InterfaceGuid $function.InterfaceGuids).Free
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $InstanceId,

        [string] $PortName,

        [AllowEmptyCollection()]
        [string[]] $InterfaceGuid = @()
    )

    if ($PortName) {
        $code = [FibocomFm350.UsbDevices]::TryComPort($PortName)
        if (Test-Win32Held -Code $code) {
            return [pscustomobject]@{ Free = $false; Held = 'Port'; Error = $code }
        }
    }
    foreach ($text in @($InterfaceGuid | Where-Object { $_ })) {
        $guid = [guid]::Empty
        if (-not [guid]::TryParse(([string]$text).Trim(), [ref]$guid)) {
            # No interface can be of a class that isn't one.
            continue
        }
        foreach ($path in @([FibocomFm350.UsbDevices]::GetInterfacePaths($guid, $InstanceId))) {
            $code = [FibocomFm350.UsbDevices]::TryPath($path)
            if (Test-Win32Held -Code $code) {
                return [pscustomobject]@{ Free = $false; Held = 'Interface'; Error = $code }
            }
        }
    }
    [pscustomobject]@{ Free = $true; Held = $null; Error = 0 }
}
function Get-WinUsbInfPath {
    # Windows' own winusb.inf, from the Windows folder - never through an environment variable
    # (ARCHITECTURE -> Invariants).
    Join-Path -Path ([Environment]::GetFolderPath('Windows')) -ChildPath "INF\$script:WinUsbInfName"
}

function Wait-UsbBindingTask {
    # Waits for a driver installation started on a thread of the pool, -Beat about once a second;
    # gives up after -TimeoutMs (the installation goes on, unwatched). Returns Done, NeedReboot,
    # Step and Error: Step 'TimedOut' when it didn't end in time, 'Exception' when it threw.
    param([System.Threading.Tasks.Task] $Task, [int] $TimeoutMs, [scriptblock] $Beat)

    $deadline = [Environment]::TickCount64 + $TimeoutMs
    try {
        while (-not $Task.Wait([int][Math]::Max(0, [Math]::Min(1000, $deadline - [Environment]::TickCount64)))) {
            if ([Environment]::TickCount64 -ge $deadline) {
                return [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'TimedOut'; Error = 0 }
            }
            if ($Beat) {
                & $Beat
            }
        }
    }
    catch {
        $cause = $_.Exception.GetBaseException()
        return [pscustomobject]@{ Done = $false; NeedReboot = $false; Step = 'Exception'; Error = $cause.HResult; Message = $cause.Message }
    }
    $result = $Task.Result
    [pscustomobject]@{ Done = $result.Done; NeedReboot = $result.NeedReboot; Step = $result.Step; Error = $result.Error }
}

function Install-WinUsbDriver {
    <#
    .SYNOPSIS
        Puts one of the modem's vendor functions on Windows' own WinUSB driver.
    .DESCRIPTION
        As Device Manager does when a driver is picked by hand (AT-COMMANDS section 1.2): with
        -InterfaceGuid - the AT function's, the app's interface class -, its DeviceInterfaceGUIDs
        written first, so that its interface is there at once; its class set to USBDevice; the
        generic model of Windows' winusb.inf, chosen by its hardware ID USB\MS_COMP_WINUSB, never
        by its localized name; DiInstallDevice with no window. No package is added to the driver
        store. A failure after the class changed gives the function back to its best driver.
        Never the network function (MI_00), never anything but a function of an FM350
        composition. Administrator rights. Runs on a thread of the pool: -Beat runs about once a
        second while it waits, at most -TimeoutMs.

        Returns Done, NeedReboot (Windows finishes it at the next restart), Step (where it
        failed: 'Open', 'InterfaceGuid', 'Class', 'Parameters', 'DriverList', 'Model', 'Select',
        'Install'; 'TimedOut', 'Exception') and Error (Windows' error code).
    .EXAMPLE
        Install-WinUsbDriver -InstanceId $function.InstanceId -InterfaceGuid $guid -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^USB\\VID_0E8D&PID_712[67]&MI_(0[2-9A-F]|[1-9A-F][0-9A-F])\\[^\\]+$')]
        [string] $InstanceId,

        [string] $InterfaceGuid,

        [scriptblock] $Beat,

        [ValidateRange(1000, 600000)]
        [int] $TimeoutMs = $script:UsbBindingTimeoutMs
    )

    if (-not $PSCmdlet.ShouldProcess("USB function $InstanceId", 'Install WinUSB')) {
        return
    }
    $task = [FibocomFm350.UsbDriverBinding]::StartInstallWinUsb($InstanceId, (Get-WinUsbInfPath), $script:WinUsbModelId, $script:UsbDeviceClassGuid, $InterfaceGuid)
    Wait-UsbBindingTask -Task $task -TimeoutMs $TimeoutMs -Beat $Beat
}

function Restore-UsbFunctionDriver {
    <#
    .SYNOPSIS
        Gives one of the modem's functions back to the driver Windows ranks best.
    .DESCRIPTION
        The way back from Install-WinUsbDriver: the app's interface class taken out of its
        DeviceInterfaceGUIDs (-InterfaceGuid), then DiInstallDevice with no driver named - the best
        match in the driver store, MediaTek's serial driver when it is there -; with none matching,
        a null driver: the function as Windows would leave it with no driver found. Never the
        network function. Administrator rights. Runs on a thread of the pool, -Beat about once a
        second while it waits.

        Returns Done, NeedReboot, Step ('Best', or 'Null' when no driver matched; where it failed
        otherwise) and Error.
    .EXAMPLE
        Restore-UsbFunctionDriver -InstanceId $function.InstanceId -InterfaceGuid $guid -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^USB\\VID_0E8D&PID_712[67]&MI_(0[2-9A-F]|[1-9A-F][0-9A-F])\\[^\\]+$')]
        [string] $InstanceId,

        [string] $InterfaceGuid,

        [scriptblock] $Beat,

        [ValidateRange(1000, 600000)]
        [int] $TimeoutMs = $script:UsbBindingTimeoutMs
    )

    if (-not $PSCmdlet.ShouldProcess("USB function $InstanceId", 'Restore its best driver')) {
        return
    }
    $task = [FibocomFm350.UsbDriverBinding]::StartRestore($InstanceId, $InterfaceGuid)
    Wait-UsbBindingTask -Task $task -TimeoutMs $TimeoutMs -Beat $Beat
}

function Restore-ModemUsbFunction {
    <#
    .SYNOPSIS
        Gives every function of the modems on WinUSB back to the driver Windows ranks best: what the
        uninstallation does.
    .DESCRIPTION
        The way back from WinUSB (ARCHITECTURE -> USB functions and WinUSB): the FM350s present, read
        by PnP, their vendor functions on WinUSB (Resolve-ModemRestore), each given back to its best
        driver (Restore-UsbFunctionDriver) - MediaTek's serial driver when it is in the driver store,
        none otherwise -, the app's interface class taken out of the AT port's. A function another
        program holds is left as it is (Test-UsbFunctionFree). Administrator rights; the app must
        have exited, its port closed. A modem not plugged in can't be reached: its functions stay on
        WinUSB.

        Returns Modems (how many are present) and Functions: each with Interface, Name, Role and
        Result - 'Done', 'RestartNeeded', 'InUse', 'Failed' -, Step and Error.
    .EXAMPLE
        Restore-ModemUsbFunction -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param()

    $modems = @(Resolve-ModemUsbDevice -Device @(Get-ModemPnpRecord))
    $outcomes = foreach ($function in @(Resolve-ModemRestore -Modem $modems)) {
        $entry = [ordered]@{ Interface = $function.Interface; Name = $function.Name; Role = $function.Role; Result = $null; Step = $null; Error = $null }
        if (-not $PSCmdlet.ShouldProcess("USB function $($function.InstanceId)", 'Restore its best driver')) {
            continue
        }
        try {
            if (-not (Test-UsbFunctionFree -InstanceId $function.InstanceId -InterfaceGuid @($function.InterfaceGuids | Where-Object { $_ })).Free) {
                $entry['Result'] = 'InUse'
                [pscustomobject]$entry
                continue
            }
            $options = @{ InstanceId = $function.InstanceId; Confirm = $false }
            if ($function.Role -eq 'AtPort') {
                $options['InterfaceGuid'] = $script:AppInterfaceGuid
            }
            $result = Restore-UsbFunctionDriver @options
            $entry['Result'] = if ($result.Done -and $result.NeedReboot) { 'RestartNeeded' } elseif ($result.Done) { 'Done' } else { 'Failed' }
            $entry['Step'] = $result.Step
            $entry['Error'] = $result.Error
        }
        catch {
            $entry['Result'] = 'Failed'
            $entry['Step'] = $_.Exception.GetType().Name
        }
        [pscustomobject]$entry
    }
    [pscustomobject]@{ Modems = $modems.Count; Functions = [object[]]@($outcomes) }
}