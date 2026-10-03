# Encrypted DNS (DNS over HTTPS) on the modem's adapter: reading and setting it for that interface
# alone, through the IP Helper API - never per server address for the whole system. Design:
# docs/ARCHITECTURE.md -> Network configuration; facts: docs/AT-COMMANDS.md section 11.1.

# GetInterfaceDnsSettings and SetInterfaceDnsSettings with DNS_INTERFACE_SETTINGS3: one family's
# name servers, each with its DoH template. Set with DNS_DOH_SERVER_SETTINGS_ENABLE alone: never
# the automatic template, never a fallback to unencrypted DNS.
if (-not ('FibocomFm350.InterfaceDns' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace FibocomFm350
{
    public sealed class DohServerSetting
    {
        public string Address;
        public string Template;
        public ulong Flags;
    }

    // One family's static name servers, and those of them that carry a DoH property.
    public sealed class InterfaceDnsReading
    {
        public string[] NameServers;
        public DohServerSetting[] Doh;
    }

    public static class InterfaceDns
    {
        private const uint Version3 = 3;
        private const ulong SettingIpv6 = 0x1;
        private const ulong SettingNameServer = 0x2;
        private const ulong SettingDoh = 0x1000;
        private const uint ServerPropertyVersion = 1;
        private const int DohProperty = 1;
        public const ulong DohEnable = 0x2;

        [StructLayout(LayoutKind.Sequential)]
        private struct Settings3
        {
            public uint Version;
            public ulong Flags;
            public IntPtr Domain;
            public IntPtr NameServer;
            public IntPtr SearchList;
            public uint RegistrationEnabled;
            public uint RegisterAdapterName;
            public uint EnableLLMNR;
            public uint QueryAdapterName;
            public IntPtr ProfileNameServer;
            public uint DisableUnconstrainedQueries;
            public IntPtr SupplementalSearchList;
            public uint ServerPropertyCount;
            public IntPtr ServerProperties;
            public uint ProfileServerPropertyCount;
            public IntPtr ProfileServerProperties;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ServerProperty
        {
            public uint Version;
            public uint ServerIndex;
            public int Type;
            public IntPtr Property;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DohSettings
        {
            public IntPtr Template;
            public ulong Flags;
        }

        [DllImport("iphlpapi.dll")]
        private static extern uint GetInterfaceDnsSettings(Guid iface, ref Settings3 settings);

        [DllImport("iphlpapi.dll")]
        private static extern void FreeInterfaceDnsSettings(ref Settings3 settings);

        [DllImport("iphlpapi.dll")]
        private static extern uint SetInterfaceDnsSettings(Guid iface, ref Settings3 settings);

        // One family's static name servers - never the ones Windows lists on its own, nor DHCP's -
        // and those that carry a DoH property, with its template and flags. Throws a
        // Win32Exception when Windows refuses the read.
        public static InterfaceDnsReading Read(Guid iface, bool ipv6)
        {
            var settings = new Settings3 { Version = Version3, Flags = ipv6 ? SettingIpv6 : 0 };
            uint error = GetInterfaceDnsSettings(iface, ref settings);
            if (error != 0)
            {
                throw new Win32Exception((int)error);
            }
            try
            {
                string names = Marshal.PtrToStringUni(settings.NameServer) ?? "";
                string[] servers = names.Split(new[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries);
                var found = new List<DohServerSetting>();
                int size = Marshal.SizeOf(typeof(ServerProperty));
                for (int i = 0; i < settings.ServerPropertyCount && settings.ServerProperties != IntPtr.Zero; i++)
                {
                    var property = (ServerProperty)Marshal.PtrToStructure(IntPtr.Add(settings.ServerProperties, i * size), typeof(ServerProperty));
                    if (property.Type != DohProperty || property.Property == IntPtr.Zero)
                    {
                        continue;
                    }
                    var doh = (DohSettings)Marshal.PtrToStructure(property.Property, typeof(DohSettings));
                    found.Add(new DohServerSetting
                    {
                        Address = property.ServerIndex < servers.Length ? servers[property.ServerIndex] : null,
                        Template = Marshal.PtrToStringUni(doh.Template),
                        Flags = doh.Flags
                    });
                }
                return new InterfaceDnsReading { NameServers = servers, Doh = found.ToArray() };
            }
            finally
            {
                FreeInterfaceDnsSettings(ref settings);
            }
        }

        // Sets one family's servers, and a DoH property for the server at each of indexes, with
        // the template at the same position: no other server is encrypted, none at all with no
        // index. Returns Windows' error code: 0 is success. (Which servers is decided in
        // PowerShell, Get-DohServerProperty: a $null that PowerShell puts in a string array
        // arrives here as an empty string.)
        public static uint Write(Guid iface, bool ipv6, string[] servers, int[] indexes, string[] templates)
        {
            var memory = new List<IntPtr>();
            try
            {
                IntPtr names = Marshal.StringToHGlobalUni(string.Join(",", servers));
                memory.Add(names);
                int propertySize = Marshal.SizeOf(typeof(ServerProperty));
                int dohSize = Marshal.SizeOf(typeof(DohSettings));
                IntPtr properties = IntPtr.Zero;
                uint count = 0;
                for (int i = 0; i < indexes.Length; i++)
                {
                    if (properties == IntPtr.Zero)
                    {
                        properties = Marshal.AllocHGlobal(propertySize * indexes.Length);
                        memory.Add(properties);
                    }
                    IntPtr template = Marshal.StringToHGlobalUni(templates[i]);
                    memory.Add(template);
                    IntPtr doh = Marshal.AllocHGlobal(dohSize);
                    memory.Add(doh);
                    Marshal.StructureToPtr(new DohSettings { Template = template, Flags = DohEnable }, doh, false);
                    var property = new ServerProperty { Version = ServerPropertyVersion, ServerIndex = (uint)indexes[i], Type = DohProperty, Property = doh };
                    Marshal.StructureToPtr(property, IntPtr.Add(properties, (int)count * propertySize), false);
                    count++;
                }
                var settings = new Settings3
                {
                    Version = Version3,
                    Flags = SettingNameServer | SettingDoh | (ipv6 ? SettingIpv6 : 0),
                    NameServer = names,
                    ServerPropertyCount = count,
                    ServerProperties = count > 0 ? properties : IntPtr.Zero
                };
                return SetInterfaceDnsSettings(iface, ref settings);
            }
            finally
            {
                foreach (IntPtr block in memory)
                {
                    Marshal.FreeHGlobal(block);
                }
            }
        }
    }
}
'@
}

function Get-InterfaceDoh {
    <#
    .SYNOPSIS
        Reads the DNS-over-HTTPS settings of one network interface.
    .DESCRIPTION
        Reads only; needs no administrator rights. Returns Supported - this Windows has the
        per-interface DoH API and the DnsClient module's DoH cmdlets, which Windows 10 lacks
        (docs/AT-COMMANDS.md section 11.1) -; Read - $false when Windows refused to read a family:
        what this reading says is then incomplete, not "none" -; NameServers, the interface's
        static name servers, IPv4 then IPv6 - never the ones Windows lists on its own, nor
        DHCP's -; and Servers: each of them that carries a DoH property, with its Address,
        Template and Flags.
    .EXAMPLE
        Get-InterfaceDoh -InterfaceGuid $adapter.InterfaceGuid
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [guid] $InterfaceGuid
    )

    $names = [System.Collections.Generic.List[string]]::new()
    $servers = [System.Collections.Generic.List[object]]::new()
    $read = $true
    $supported = [bool](Get-Command -Name 'Get-DnsClientDohServerAddress' -ErrorAction SilentlyContinue)
    if ($supported) {
        foreach ($ipv6 in $false, $true) {
            try {
                $reading = Read-InterfaceDnsFamily -InterfaceGuid $InterfaceGuid -IPv6 $ipv6
            }
            catch {
                $cause = $_.Exception.GetBaseException()
                if ($cause -is [System.EntryPointNotFoundException] -or $cause -is [System.DllNotFoundException]) {
                    # The function is missing: a Windows without it.
                    Write-Verbose "No per-interface DoH: $($cause.Message)"
                    $supported = $false
                    $names.Clear()
                    $servers.Clear()
                    break
                }
                # Windows refused this read: unknown, never "none" - the other family still counts.
                Write-Verbose "The $(if ($ipv6) { 'IPv6' } else { 'IPv4' }) DNS settings can't be read: $($cause.Message)"
                $read = $false
                continue
            }
            foreach ($name in @($reading.NameServers)) {
                $names.Add($name)
            }
            foreach ($setting in @($reading.Doh)) {
                if ($setting.Address) {
                    $servers.Add([pscustomobject]@{ Address = $setting.Address; Template = $setting.Template; Flags = [uint64]$setting.Flags })
                }
            }
        }
    }
    [pscustomobject]@{ Supported = $supported; Read = $read; NameServers = [string[]]$names.ToArray(); Servers = [object[]]$servers.ToArray() }
}

function Read-InterfaceDnsFamily {
    # One family's static name servers and DoH properties, as Windows gives them; throws when it
    # refuses (a Win32Exception), or when the function is missing.
    param([guid] $InterfaceGuid, [bool] $IPv6)

    [FibocomFm350.InterfaceDns]::Read($InterfaceGuid, $IPv6)
}

function Get-DohKnownServer {
    <#
    .SYNOPSIS
        The servers Windows knows a DoH template for: a dictionary of address to template.
    .DESCRIPTION
        Windows' list, which Add-DnsClientDohServerAddress extends (docs/AT-COMMANDS.md section
        11.1). Nothing on a Windows without DoH, and nothing when Windows can't give its list -
        the connect pass goes on: only a server that needs a template from it waits, for the next
        pass. Reads only.
    .EXAMPLE
        (Get-DohKnownServer)['1.1.1.1']
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if (-not (Get-Command -Name 'Get-DnsClientDohServerAddress' -ErrorAction SilentlyContinue)) {
        return
    }
    $known = @{}
    try {
        foreach ($server in @(Get-DnsClientDohServerAddress -ErrorAction Stop)) {
            # An entry that names no address is passed over, never the whole list.
            $address = $null
            if ($server.DohTemplate -and [System.Net.IPAddress]::TryParse([string]$server.ServerAddress, [ref]$address)) {
                $known[$address.ToString()] = [string]$server.DohTemplate
            }
        }
    }
    catch {
        Write-Verbose "Windows' DoH servers can't be read: $($_.Exception.Message)"
        return
    }
    $known
}

function Get-DohServerProperty {
    # The DoH properties Set-InterfaceDoh writes: Index (the server's position in -Servers) and
    # Template, for each server whose template in -Templates, at the same position, is given -
    # never an empty one, which Windows refuses (docs/AT-COMMANDS.md section 11.1). A pure
    # decision.
    param([string[]] $Servers, [string[]] $Templates)

    for ($i = 0; $i -lt @($Servers).Count; $i++) {
        if ($Templates -and $i -lt $Templates.Count -and -not [string]::IsNullOrWhiteSpace($Templates[$i])) {
            [pscustomobject]@{ Index = $i; Template = $Templates[$i] }
        }
    }
}

function Set-InterfaceDoh {
    <#
    .SYNOPSIS
        Sets one family's DNS servers on an interface, each encrypted with its DoH template.
    .DESCRIPTION
        -Templates holds one template per server, in order; a $null one leaves that server
        unencrypted, and all $null removes DoH from them. Encrypted only - never Windows'
        automatic template, never a fallback to unencrypted DNS. Needs administrator rights;
        throws when Windows refuses, with its error.
    .EXAMPLE
        Set-InterfaceDoh -InterfaceGuid $guid -Family IPv4 -Servers '1.1.1.1' -Templates 'https://cloudflare-dns.com/dns-query'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [guid] $InterfaceGuid,

        [Parameter(Mandatory)]
        [ValidateSet('IPv4', 'IPv6')]
        [string] $Family,

        [Parameter(Mandatory)]
        [string[]] $Servers,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Templates
    )

    if (-not $PSCmdlet.ShouldProcess("interface $InterfaceGuid", "Set the $Family DNS servers and their encryption")) {
        return
    }
    $properties = @(Get-DohServerProperty -Servers $Servers -Templates $Templates)
    $code = [FibocomFm350.InterfaceDns]::Write($InterfaceGuid, $Family -eq 'IPv6', $Servers, [int[]]@($properties | ForEach-Object Index), [string[]]@($properties | ForEach-Object Template))
    if ($code -ne 0) {
        throw [System.ComponentModel.Win32Exception]::new([int]$code)
    }
}

function Get-DohTemplateHost {
    # The host a DoH template names - a name or an address -, or $null for no usable template.
    param([string] $Template)

    $uri = $null
    if ($Template -and [uri]::TryCreate($Template, [System.UriKind]::Absolute, [ref]$uri) -and $uri.Host) {
        return $uri.Host.Trim('[', ']')
    }
    $null
}

function Resolve-DohServer {
    <#
    .SYNOPSIS
        Decides which DNS servers encrypted DNS goes to, and which name must be looked up for them.
    .DESCRIPTION
        A pure decision from -Settings and -Resolved, the IPv4 addresses the DoH template's name
        was last looked up to. Windows binds encryption to a server address, never to a name
        (docs/AT-COMMANDS.md section 11.1): the servers are those of the DNS override; without
        any, the DoH template's host - its address when it is one, else the addresses its name was
        looked up to. Returns Servers (for the adapter plan), Name (the host name to look up, or
        $null: nothing to look up) and Pending ($true while that name has no address yet).
    .EXAMPLE
        Resolve-DohServer -Settings $settings -Resolved '203.0.113.53'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Settings,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $Resolved
    )

    $override = [string[]]@($Settings.DnsServers | Where-Object { $_ })
    $doh = $Settings.PSObject.Properties['DnsOverHttps'] -and $Settings.DnsOverHttps -eq $true
    $template = if ($Settings.PSObject.Properties['DohTemplate']) { [string]$Settings.DohTemplate } else { '' }
    $name = Get-DohTemplateHost -Template $template
    if (-not $doh -or $override.Count -gt 0 -or -not $name) {
        return [pscustomobject]@{ Servers = $override; Name = $null; Pending = $false }
    }
    $address = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$address)) {
        return [pscustomobject]@{ Servers = [string[]]@($address.ToString()); Name = $null; Pending = $false }
    }
    $servers = [string[]]@($Resolved | Where-Object { $_ })
    [pscustomobject]@{ Servers = $servers; Name = $name; Pending = $servers.Count -eq 0 }
}

function ConvertTo-DnsQuery {
    # A DNS query for the IPv4 addresses of -Name (docs/AT-COMMANDS.md section 11.1, RFC 1035
    # section 4.1): the header with -Id and recursion desired, one question of type A, class IN.
    # Throws for a name DNS can't carry.
    param([uint16] $Id, [string] $Name)

    # International names travel in their ASCII form; GetAscii refuses empty or over-long labels.
    $ascii = [System.Globalization.IdnMapping]::new().GetAscii($Name.TrimEnd('.'))
    if ($ascii.Length -gt 253) {
        throw [System.ArgumentException]::new("'$Name' is longer than a DNS name may be.")
    }
    $query = [System.Collections.Generic.List[byte]]::new()
    $query.AddRange([byte[]]@(($Id -shr 8), ($Id -band 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0))
    foreach ($label in $ascii.Split('.')) {
        $query.Add([byte]$label.Length)
        $query.AddRange([System.Text.Encoding]::ASCII.GetBytes($label))
    }
    $query.AddRange([byte[]]@(0, 0, 1, 0, 1))
    $query.ToArray()
}

function Get-DnsNameEnd {
    # Where the name that starts at -At in a DNS message ends (RFC 1035 sections 4.1.2 and 4.1.4):
    # labels up to a zero length, or up to a pointer. Throws past the message's end.
    param([byte[]] $Data, [int] $At)

    while ($true) {
        if ($At -ge $Data.Count) {
            throw [System.FormatException]::new('A name runs past the end of the message.')
        }
        $length = $Data[$At]
        if ($length -eq 0) {
            return $At + 1
        }
        if (($length -band 0xC0) -eq 0xC0) {
            return $At + 2
        }
        if ($length -band 0xC0) {
            throw [System.FormatException]::new('A label has a reserved length.')
        }
        $At += 1 + $length
    }
}

function ConvertFrom-DnsResponse {
    # The IPv4 addresses in a DNS server's answer to -Query, ConvertTo-DnsQuery's (RFC 1035
    # section 4.1): an answer with the query's ID and its question - name, type and class
    # (RFC 5452 section 9.1) -, then every record of type A, class IN in the answer section, an
    # alias's too. Returns Addresses (as text) and Failure, why there are none.
    param([byte[]] $Data, [byte[]] $Query)

    $fail = { param($why) [pscustomobject]@{ Addresses = [string[]]@(); Failure = $why } }
    # A 16-bit number, high byte first; a byte shifted in PowerShell stays a byte.
    $word = { param($at) ([int]$Data[$at] -shl 8) -bor $Data[$at + 1] }
    # The question, compared without regard to case, as DNS compares names - ordinally: a
    # comparison by culture skips the control characters that lengths and types are made of.
    $question = [System.Text.Encoding]::ASCII.GetString($Query, 12, $Query.Count - 12)
    $asked = $Data.Count -ge $Query.Count -and $Data[0] -eq $Query[0] -and $Data[1] -eq $Query[1] -and ($Data[2] -band 0x80) -and (& $word 4) -eq 1
    if ($asked) {
        $echoed = [System.Text.Encoding]::ASCII.GetString($Data, 12, $Query.Count - 12)
        $asked = [string]::Equals($echoed, $question, [System.StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $asked) {
        return & $fail 'The answer is not one to this query.'
    }
    if ($Data[2] -band 0x02) {
        return & $fail 'The answer was cut short.'
    }
    $code = $Data[3] -band 0x0F
    if ($code -eq 3) {
        return & $fail 'No such host is known.'
    }
    if ($code -ne 0) {
        return & $fail "The DNS server answered with error $code."
    }
    $records = & $word 6
    $addresses = [System.Collections.Generic.List[string]]::new()
    try {
        $at = $Query.Count
        for ($i = 0; $i -lt $records; $i++) {
            $at = Get-DnsNameEnd -Data $Data -At $at
            if ($at + 10 -gt $Data.Count) {
                throw [System.FormatException]::new('A record runs past the end of the message.')
            }
            $type = & $word $at
            $class = & $word ($at + 2)
            $length = & $word ($at + 8)
            $at += 10
            if ($at + $length -gt $Data.Count) {
                throw [System.FormatException]::new('A record runs past the end of the message.')
            }
            if ($type -eq 1 -and $class -eq 1 -and $length -eq 4) {
                $addresses.Add(([System.Net.IPAddress]::new([byte[]]$Data[$at..($at + 3)])).ToString())
            }
            $at += $length
        }
    }
    catch [System.FormatException] {
        return & $fail 'The answer is malformed.'
    }
    if ($addresses.Count -eq 0) {
        return & $fail 'The name has no IPv4 address.'
    }
    [pscustomobject]@{ Addresses = [string[]]$addresses.ToArray(); Failure = $null }
}

function Start-DohNameLookup {
    <#
    .SYNOPSIS
        Starts looking up the IPv4 addresses of a DoH server's name, and returns at once.
    .DESCRIPTION
        By default through Windows' own resolver, as any name is looked up - on every interface,
        the encrypted one of the modem's adapter too while it works. With -Servers and -Source:
        one query to each of those DNS servers - the operator's -, in the clear, over UDP from
        -Source, the modem's address, which Windows sends through the adapter that carries it
        (docs/AT-COMMANDS.md section 11.1); the first answer counts. Returns the lookup under way
        (Name, Via: 'Windows' or 'Operator', Task, and what reads the answer);
        Receive-DohNameLookup reads it once done, Stop-DohNameLookup drops it. The worker never
        waits on it.
    .EXAMPLE
        $lookup = Start-DohNameLookup -Name 'dns.example.org'
    .EXAMPLE
        $lookup = Start-DohNameLookup -Name 'dns.example.org' -Servers '192.0.2.53' -Source '198.51.100.23'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sends a DNS query; changes no system state.')]
    [CmdletBinding(DefaultParameterSetName = 'Windows')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory, ParameterSetName = 'Operator')]
        [string[]] $Servers,

        [Parameter(Mandatory, ParameterSetName = 'Operator')]
        [string] $Source,

        # The servers' port: 53, DNS's own.
        [Parameter(ParameterSetName = 'Operator')]
        [int] $Port = 53
    )

    if ($PSCmdlet.ParameterSetName -eq 'Windows') {
        $task = [System.Net.Dns]::GetHostAddressesAsync($Name, [System.Net.Sockets.AddressFamily]::InterNetwork)
        return [pscustomobject]@{ Name = $Name; Via = 'Windows'; Task = $task; Client = $null; Query = $null; Servers = $null }
    }
    # A random ID and a random port: an answer must match both (RFC 5452).
    $id = [uint16][System.Security.Cryptography.RandomNumberGenerator]::GetInt32(65536)
    $client = $null
    $query = $null
    try {
        $query = ConvertTo-DnsQuery -Id $id -Name $Name
        $client = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Source), 0))
        foreach ($server in $Servers) {
            [void]$client.Send($query, $query.Length, [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($server), $Port))
        }
        $task = $client.ReceiveAsync()
    }
    catch {
        # The modem's address not on its adapter yet, a server that is no address: a failed lookup.
        if ($client) {
            $client.Dispose()
            $client = $null
        }
        $task = [System.Threading.Tasks.Task]::FromException($_.Exception.GetBaseException())
    }
    [pscustomobject]@{ Name = $Name; Via = 'Operator'; Task = $task; Client = $client; Query = $query; Servers = [string[]]$Servers }
}

function Receive-DohNameLookup {
    <#
    .SYNOPSIS
        Reads a lookup of Start-DohNameLookup's once it has ended.
    .DESCRIPTION
        Returns nothing while it is under way; then Addresses (the IPv4 addresses, as text) and
        Failure (why there are none). An answer from the operator's DNS counts only from one of
        the servers asked, to the query sent.
    .EXAMPLE
        $result = Receive-DohNameLookup -Lookup $lookup
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Lookup
    )

    $task = $Lookup.Task
    if (-not $task.IsCompleted) {
        return
    }
    Stop-DohNameLookup -Lookup $Lookup
    if ($task.IsFaulted -or $task.IsCanceled) {
        $why = if ($task.IsCanceled) { 'The lookup was cancelled.' } else { $task.Exception.GetBaseException().Message }
        return [pscustomobject]@{ Addresses = [string[]]@(); Failure = $why }
    }
    if ($Lookup.Via -eq 'Operator') {
        $answer = $task.Result
        if ($answer.RemoteEndPoint.Address.ToString() -notin $Lookup.Servers) {
            return [pscustomobject]@{ Addresses = [string[]]@(); Failure = 'The answer came from another address.' }
        }
        return ConvertFrom-DnsResponse -Data $answer.Buffer -Query $Lookup.Query
    }
    $addresses = [string[]]@($task.Result | Where-Object AddressFamily -EQ 'InterNetwork' | ForEach-Object { $_.ToString() })
    [pscustomobject]@{ Addresses = $addresses; Failure = $(if ($addresses.Count -eq 0) { 'The name has no IPv4 address.' } else { $null }) }
}

function Stop-DohNameLookup {
    <#
    .SYNOPSIS
        Drops a lookup of Start-DohNameLookup's: closes the socket a query to the operator's DNS
        holds. Nothing for a lookup through Windows, or one already read.
    .EXAMPLE
        Stop-DohNameLookup -Lookup $lookup
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Closes a socket this module opened; changes no system state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Lookup
    )

    if ($Lookup.Client) {
        $Lookup.Client.Dispose()
        $Lookup.Client = $null
    }
}
