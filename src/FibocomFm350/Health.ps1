# Health checks: which of H1-H7 fails, told from the connection's state, and the data-path probe
# (H7). Design: docs/ARCHITECTURE.md -> Health checks and the recovery ladder.

# The data-path probe (H7): ICMP echo requests sent from the modem's address, so that they leave
# through the modem whatever the routes prefer - the modem is usually a backup, its metric above
# every other adapter's. Target and interval: the maintainer's decision (ROADMAP M4).
$script:DataProbe = @{
    # Where the requests go, in turn.
    Targets      = @('1.1.1.1', '8.8.8.8')
    # A round: up to this many requests, each waiting this long for its reply; the first reply
    # passes the round.
    Requests     = 3
    TimeoutMs    = 1000
    # Rounds failed in a row that fail H7: one lost round is never a failure.
    FailedRounds = 2
    # The next round, after one that passed and after one that failed.
    IntervalMs   = 60000
    RetryMs      = 10000
    # The first round after the adapter's address was set, or after a recovery step.
    SettleMs     = 5000
    # Rounds remembered for one address.
    RoundsKept   = 10
}

# ICMP echo from a given source address, through the IP Helper API: .NET's Ping can't choose the
# address it sends from.
if (-not ('FibocomFm350.IcmpEcho' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Runtime.InteropServices;

namespace FibocomFm350
{
    public static class IcmpEcho
    {
        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern IntPtr IcmpCreateFile();

        [DllImport("iphlpapi.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IcmpCloseHandle(IntPtr icmpHandle);

        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint IcmpSendEcho2Ex(IntPtr icmpHandle, IntPtr eventHandle, IntPtr apcRoutine,
            IntPtr apcContext, uint sourceAddress, uint destinationAddress, byte[] requestData,
            ushort requestSize, IntPtr requestOptions, IntPtr replyBuffer, uint replySize, uint timeout);

        // Sends one echo request and waits for its reply. Returns the IP status: 0 for a reply,
        // otherwise why there was none (11010 timed out, 11050 general failure...).
        public static int Send(string source, string destination, int timeoutMs)
        {
            uint from = BitConverter.ToUInt32(IPAddress.Parse(source).GetAddressBytes(), 0);
            uint to = BitConverter.ToUInt32(IPAddress.Parse(destination).GetAddressBytes(), 0);
            byte[] data = new byte[8];
            const int replySize = 256;
            IntPtr handle = IcmpCreateFile();
            if (handle == new IntPtr(-1))
            {
                return Marshal.GetLastWin32Error();
            }
            IntPtr reply = Marshal.AllocHGlobal(replySize);
            try
            {
                uint replies = IcmpSendEcho2Ex(handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, from, to,
                    data, (ushort)data.Length, IntPtr.Zero, reply, replySize, (uint)timeoutMs);
                if (replies == 0)
                {
                    int error = Marshal.GetLastWin32Error();
                    return error == 0 ? -1 : error;
                }
                // ICMP_ECHO_REPLY: the replying address, then the status.
                return Marshal.ReadInt32(reply, 4);
            }
            finally
            {
                Marshal.FreeHGlobal(reply);
                IcmpCloseHandle(handle);
            }
        }
    }
}
'@
}

function Resolve-HealthCheck {
    <#
    .SYNOPSIS
        Tells which health check fails, from the connection's state.
    .DESCRIPTION
        A pure decision. The connect pass already reads what the checks need, from the cheapest
        to the most expensive, and stops at the first that fails: the state it reaches says
        which one (ARCHITECTURE -> Health checks):
        - H1 device present: no modem, no driver, a device problem;
        - H2 AT port answers: the port open but silent, or it can't be opened;
        - H3 SIM ready; H4 registered; H5 data context up, with an address;
        - H6 adapter configured: the context's address on the modem's adapter;
        - H7 data path: the probes bound to that address get no answer.
        Online, every check passes.

        The data context is defined before the registration is looked at (the state machine
        writes a definition while the modem registers), so a missing definition - -Action
        'DefineContext' - is H5 even in the state before registration.

        Returns Check ('H1' to 'H7', or $null when healthy); Blocked: what fails is out of the
        app's reach (-Blocked, from Resolve-ConnectionState), or another program holds the AT
        port - no recovery step is ever taken under it; and Unknown: the state couldn't be read
        (SimUnknown, ContextUnknown) - what can't be read is never taken for a failure
        (ARCHITECTURE -> Connection state machine).
    .EXAMPLE
        Resolve-HealthCheck -State 'DataActive' -Reason 'DataPathFailed'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('NoDevice', 'PortOpen', 'Identified', 'SimReady', 'Registered', 'DataActive', 'Online')]
        [string] $State,

        [string] $Reason,

        [string] $Action,

        [switch] $Blocked
    )

    $check = switch ($State) {
        'NoDevice' { if ($Reason -in 'NoDevice', 'NoDriver', 'DeviceProblem') { 'H1' } else { 'H2' } }
        'PortOpen' { 'H2' }
        'Identified' { 'H3' }
        'SimReady' { if ($Action -eq 'DefineContext') { 'H5' } else { 'H4' } }
        'Registered' { 'H5' }
        'DataActive' { if ($Reason -eq 'DataPathFailed') { 'H7' } else { 'H6' } }
        'Online' { $null }
        default { $null }
    }
    [pscustomobject]@{
        Check   = $check
        Blocked = [bool]$check -and ($Blocked -or $Reason -eq 'PortInUse')
        Unknown = [bool]$check -and $Reason -in 'SimUnknown', 'ContextUnknown'
    }
}

function Resolve-DataPathHealth {
    <#
    .SYNOPSIS
        Tells whether the data path works, from the probe rounds sent from one address.
    .DESCRIPTION
        A pure decision over -Rounds, the results of the rounds sent from the adapter's current
        address, oldest first: 'Passed' (a reply) or 'Failed' (none). A round that could not be
        sent - the address not usable yet - is not a round.

        Returns $false when the last FailedRounds rounds all failed: one lost round is never a
        failure, a path that is settling loses some. $true when a round passed. $null when
        nothing is proven yet - and, with -Unproven, when no round has passed since the app
        started: rounds that were never answered prove nothing on a network that drops ICMP, and
        are never taken for a failure (decided 2026-10-02).
    .EXAMPLE
        Resolve-DataPathHealth -Rounds 'Passed', 'Failed'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Rounds = @(),

        [ValidateRange(1, 100)]
        [int] $FailedRounds = $script:DataProbe.FailedRounds,

        [switch] $Unproven
    )

    $recent = @($Rounds | Select-Object -Last $FailedRounds)
    if (-not $Unproven -and $recent.Count -ge $FailedRounds -and @($recent | Where-Object { $_ -ne 'Failed' }).Count -eq 0) {
        return $false
    }
    if ($Rounds -contains 'Passed') {
        return $true
    }
    $null
}

function Test-ModemDataPath {
    <#
    .SYNOPSIS
        Sends one probe round from the modem's address: does traffic get through the modem?
    .DESCRIPTION
        ICMP echo requests from -SourceAddress to the targets in turn, up to -Requests of them,
        each waiting -TimeoutMs for its reply; the first reply ends the round. Bound to the
        modem's address, they leave through the modem whatever the routes prefer.

        A round is sent only from an address Windows has made usable: one just set is
        'Tentative' while Windows checks that no other host has it, and a request from it fails
        at once - that is no fault of the path. Needs no administrator rights; changes nothing.

        Returns Result - 'Passed', 'Failed' or 'NotReady' (the address is missing or not usable
        yet: no request sent) - Sent (requests sent), Status (the IP status of the last request:
        0 a reply, 11010 timed out, 11050 general failure...) and AddressState.
    .EXAMPLE
        Test-ModemDataPath -SourceAddress 192.0.2.10
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
        [string] $SourceAddress,

        [ValidateNotNullOrEmpty()]
        [string[]] $Target = $script:DataProbe.Targets,

        [ValidateRange(1, 10)]
        [int] $Requests = $script:DataProbe.Requests,

        [ValidateRange(100, 10000)]
        [int] $TimeoutMs = $script:DataProbe.TimeoutMs
    )

    $address = Get-NetIPAddress -IPAddress $SourceAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $state = if ($address) { [string]$address.AddressState } else { 'Missing' }
    if ($state -ne 'Preferred') {
        return [pscustomobject]@{ Result = 'NotReady'; Sent = 0; Status = $null; AddressState = $state }
    }
    $status = $null
    $sent = 0
    for ($i = 0; $i -lt $Requests; $i++) {
        $status = [FibocomFm350.IcmpEcho]::Send($SourceAddress, $Target[$i % $Target.Count], $TimeoutMs)
        $sent++
        if ($status -eq 0) {
            break
        }
    }
    [pscustomobject]@{
        Result       = if ($status -eq 0) { 'Passed' } else { 'Failed' }
        Sent         = $sent
        Status       = $status
        AddressState = $state
    }
}
