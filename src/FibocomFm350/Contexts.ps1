# Parsers for the data context: its definition, activation, dynamic parameters (address, gateway,
# DNS), authentication, and the vendor's DNS read. Facts and sources: docs/AT-COMMANDS.md sections
# 3 and 4.
#
# Pure, like the status parsers in Parsers.ps1: answer lines in, objects out; lines with other
# prefixes are ignored.

# 27.007 <auth_prot>.
$script:AuthenticationProtocols = @{ 0 = 'None'; 1 = 'PAP'; 2 = 'CHAP' }

function ConvertFrom-AtAddressField {
    # An address field as the modem writes it: dotted decimal numbers - 4 for an IPv4 address, 8
    # for an IPv4 address and its mask, 16 for an IPv6 address, 32 for an IPv6 address and its mask
    # - or an IPv6 address in text form. Returns Family ('IPv4' or 'IPv6'), Address (in the usual
    # text form) and PrefixLength ($null without a mask, or for a mask that isn't contiguous), or
    # nothing for an empty or unreadable field.
    param([AllowEmptyString()] [string] $Text)

    $text = $Text.Trim()
    if (-not $text) {
        return
    }
    if ($text.Contains(':')) {
        $parsed = $null
        if ([System.Net.IPAddress]::TryParse($text, [ref]$parsed)) {
            [pscustomobject]@{ Family = 'IPv6'; Address = $parsed.ToString(); PrefixLength = $null }
        }
        return
    }
    $numbers = $text.Split('.')
    if ($numbers.Count -notin 4, 8, 16, 32 -or @($numbers | Where-Object { $_ -notmatch '^\d{1,3}$' -or [int]$_ -gt 255 }).Count -gt 0) {
        return
    }
    $bytes = [byte[]]@($numbers | ForEach-Object { [byte]$_ })
    $size = if ($numbers.Count -in 4, 8) { 4 } else { 16 }
    $prefixLength = $null
    if ($bytes.Count -eq 2 * $size) {
        # The mask: ones, then zeros.
        $bits = -join @($bytes[$size..($bytes.Count - 1)] | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') })
        if ($bits -match '^1*0*$') {
            $prefixLength = $bits.IndexOf([char]'0')
            if ($prefixLength -lt 0) {
                $prefixLength = $bits.Length
            }
        }
    }
    [pscustomobject]@{
        Family       = if ($size -eq 4) { 'IPv4' } else { 'IPv6' }
        Address      = [System.Net.IPAddress]::new([byte[]]$bytes[0..($size - 1)]).ToString()
        PrefixLength = $prefixLength
    }
}

function ConvertFrom-AtContextDefinition {
    <#
    .SYNOPSIS
        Reads the defined data contexts from the answer to AT+CGDCONT?.
    .DESCRIPTION
        One '+CGDCONT: <cid>,<PDP_type>,<APN>,...' line per context. Returns one object per
        context: Cid, PdpType ('IP', 'IPV6', 'IPV4V6') and Apn ('' for an empty APN: the
        subscription's own). An answer with no context gives nothing.
    .EXAMPLE
        ConvertFrom-AtContextDefinition -Lines '+CGDCONT: 1,"IPV4V6","internet","",0,0'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($text in Get-AtPrefixedLine -Lines $Lines -Prefix '+CGDCONT') {
        $arguments = @(Split-AtArgument -Text $text)
        $cid = ConvertTo-AtInteger -Text $arguments[0].Value
        if ($null -eq $cid -or $arguments.Count -lt 2) {
            continue
        }
        [pscustomobject]@{
            Cid     = $cid
            PdpType = $arguments[1].Value.ToUpperInvariant()
            Apn     = if ($arguments.Count -gt 2) { $arguments[2].Value } else { '' }
        }
    }
}

function ConvertFrom-AtContextActivation {
    <#
    .SYNOPSIS
        Reads which data contexts are active from the answer to AT+CGACT?.
    .DESCRIPTION
        One '+CGACT: <cid>,<state>' line per context. Returns one object per context: Cid and
        Active ($true for state 1).
    .EXAMPLE
        ConvertFrom-AtContextActivation -Lines '+CGACT: 1,1'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($text in Get-AtPrefixedLine -Lines $Lines -Prefix '+CGACT') {
        $arguments = @(Split-AtArgument -Text $text)
        $cid = ConvertTo-AtInteger -Text $arguments[0].Value
        $state = if ($arguments.Count -gt 1) { ConvertTo-AtInteger -Text $arguments[1].Value }
        if ($null -eq $cid -or $null -eq $state) {
            continue
        }
        [pscustomobject]@{ Cid = $cid; Active = $state -eq 1 }
    }
}

function ConvertFrom-AtContextParameter {
    <#
    .SYNOPSIS
        Reads the address, gateway and DNS servers of active data contexts from the answer to
        AT+CGCONTRDP.
    .DESCRIPTION
        '+CGCONTRDP: <cid>,<bearer_id>,<apn>,<address and mask>,<gateway>,<DNS 1>,<DNS 2>,...'.
        The address and its mask are one field: 8 dotted numbers for IPv4, 32 for IPv6. A dual
        stack context gives an IPv4 line and an IPv6 line, and more DNS servers add lines; a
        line's family is that of its first address. Missing values are empty strings.

        Returns one object per context: Cid, BearerId, Apn, IPv4Address, IPv4PrefixLength,
        IPv4Gateway, IPv6Address, IPv6PrefixLength, IPv6Gateway, Dns (the IPv4 servers, then the
        IPv6 ones) and Mtu (the IPv4 MTU); $null for what the answer doesn't carry.
    .EXAMPLE
        ConvertFrom-AtContextParameter -Lines '+CGCONTRDP: 1,5,"internet","198.51.100.7.255.255.255.0","198.51.100.1","203.0.113.53",""'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    $contexts = [ordered]@{}
    foreach ($text in Get-AtPrefixedLine -Lines $Lines -Prefix '+CGCONTRDP') {
        $arguments = @(Split-AtArgument -Text $text)
        $cid = ConvertTo-AtInteger -Text $arguments[0].Value
        if ($null -eq $cid) {
            continue
        }
        $value = { param($i) if ($arguments.Count -gt $i) { $arguments[$i].Value } else { '' } }
        # String keys: an ordered dictionary reads an integer key as a position.
        if (-not $contexts.Contains("$cid")) {
            $contexts["$cid"] = [pscustomobject]@{
                Cid = $cid; BearerId = $null; Apn = $null
                IPv4Address = $null; IPv4PrefixLength = $null; IPv4Gateway = $null
                IPv6Address = $null; IPv6PrefixLength = $null; IPv6Gateway = $null
                Dns = @(); Mtu = $null
                DnsByFamily = @{ IPv4 = [System.Collections.Generic.List[string]]::new(); IPv6 = [System.Collections.Generic.List[string]]::new() }
            }
        }
        $context = $contexts["$cid"]
        $context.BearerId ??= ConvertTo-AtInteger -Text (& $value 1)
        if (-not $context.Apn) {
            $context.Apn = & $value 2
        }
        $context.Mtu ??= ConvertTo-AtInteger -Text (& $value 11)

        $address = ConvertFrom-AtAddressField -Text (& $value 3)
        $gateway = ConvertFrom-AtAddressField -Text (& $value 4)
        $dns = @(ConvertFrom-AtAddressField -Text (& $value 5)) + @(ConvertFrom-AtAddressField -Text (& $value 6)) | Where-Object { $_ }
        $first = @($address, $gateway) + $dns | Where-Object { $_ } | Select-Object -First 1
        if (-not $first) {
            continue
        }
        $family = $first.Family
        if ($address -and $address.Family -eq $family -and -not $context."${family}Address") {
            $context."${family}Address" = $address.Address
            $context."${family}PrefixLength" = $address.PrefixLength
        }
        if ($gateway -and $gateway.Family -eq $family -and -not $context."${family}Gateway") {
            $context."${family}Gateway" = $gateway.Address
        }
        foreach ($server in $dns) {
            if ($server.Family -eq $family -and $server.Address -notin $context.DnsByFamily[$family]) {
                $context.DnsByFamily[$family].Add($server.Address)
            }
        }
    }

    foreach ($context in $contexts.Values) {
        $context.Dns = [string[]]@($context.DnsByFamily['IPv4']) + @($context.DnsByFamily['IPv6'])
        $context | Select-Object -Property * -ExcludeProperty DnsByFamily
    }
}

function ConvertFrom-AtContextAuthentication {
    <#
    .SYNOPSIS
        Reads the authentication set for each data context from the answer to AT+CGAUTH?.
    .DESCRIPTION
        One '+CGAUTH: <cid>,<auth_prot>,<user>,<password>' line per context. Returns one object
        per context: Cid, ProtocolCode, Protocol ('None', 'PAP', 'CHAP', or $null for another
        code), User, and PasswordSet - whether the answer carries a password. The password itself
        is never returned: a secret never leaves the parser.
    .EXAMPLE
        ConvertFrom-AtContextAuthentication -Lines '+CGAUTH: 1,1,"user",""'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($text in Get-AtPrefixedLine -Lines $Lines -Prefix '+CGAUTH') {
        $arguments = @(Split-AtArgument -Text $text)
        $cid = ConvertTo-AtInteger -Text $arguments[0].Value
        $code = if ($arguments.Count -gt 1) { ConvertTo-AtInteger -Text $arguments[1].Value }
        if ($null -eq $cid -or $null -eq $code) {
            continue
        }
        [pscustomobject]@{
            Cid          = $cid
            ProtocolCode = $code
            Protocol     = $script:AuthenticationProtocols[$code]
            User         = if ($arguments.Count -gt 2) { $arguments[2].Value } else { '' }
            PasswordSet  = $arguments.Count -gt 3 -and [bool]$arguments[3].Value
        }
    }
}

function ConvertFrom-AtDnsServer {
    <#
    .SYNOPSIS
        Reads a context's DNS servers from the answer to AT+GTDNS=<cid>.
    .DESCRIPTION
        '+GTDNS: <cid>,<DNS 1>,<DNS 2>', quoted or not. Returns one object per context: Cid and
        Dns (the servers' addresses, IPv4 before IPv6, empty ones left out).
    .EXAMPLE
        ConvertFrom-AtDnsServer -Lines '+GTDNS: 1,"203.0.113.53","203.0.113.54"'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    $contexts = [ordered]@{}
    foreach ($text in Get-AtPrefixedLine -Lines $Lines -Prefix '+GTDNS') {
        $arguments = @(Split-AtArgument -Text $text)
        $cid = ConvertTo-AtInteger -Text $arguments[0].Value
        if ($null -eq $cid) {
            continue
        }
        # String keys: an ordered dictionary reads an integer key as a position.
        if (-not $contexts.Contains("$cid")) {
            $contexts["$cid"] = @{ IPv4 = [System.Collections.Generic.List[string]]::new(); IPv6 = [System.Collections.Generic.List[string]]::new() }
        }
        foreach ($argument in @($arguments | Select-Object -Skip 1)) {
            $server = ConvertFrom-AtAddressField -Text $argument.Value
            if ($server -and $server.Address -notin $contexts["$cid"][$server.Family]) {
                $contexts["$cid"][$server.Family].Add($server.Address)
            }
        }
    }
    foreach ($key in $contexts.Keys) {
        [pscustomobject]@{
            Cid = [int]$key
            Dns = [string[]]@(@($contexts[$key]['IPv4']) + @($contexts[$key]['IPv6']))
        }
    }
}

function ConvertFrom-AtContextAddress {
    <#
    .SYNOPSIS
        Reads a context's addresses from the answer to AT+CGPADDR=<cid>.
    .DESCRIPTION
        '+CGPADDR: <cid>,<address 1>[,<address 2>]', each address in dotted numbers: 4 for
        IPv4, 16 for IPv6 (or IPv6 in text form). The family is told by the address, not by its
        position: a context with IPv6 alone gives it first. Returns one object per context: Cid,
        IPv4Address and IPv6Address ($null when absent).
    .EXAMPLE
        ConvertFrom-AtContextAddress -Lines '+CGPADDR: 1,"198.51.100.23",""'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($text in Get-AtPrefixedLine -Lines $Lines -Prefix '+CGPADDR') {
        $arguments = @(Split-AtArgument -Text $text)
        $cid = ConvertTo-AtInteger -Text $arguments[0].Value
        if ($null -eq $cid) {
            continue
        }
        $addresses = @($arguments | Select-Object -Skip 1 | ForEach-Object { ConvertFrom-AtAddressField -Text $_.Value } | Where-Object { $_ })
        $ipv4 = $addresses | Where-Object Family -EQ 'IPv4' | Select-Object -First 1
        $ipv6 = $addresses | Where-Object Family -EQ 'IPv6' | Select-Object -First 1
        [pscustomobject]@{
            Cid         = $cid
            IPv4Address = if ($ipv4) { $ipv4.Address } else { $null }
            IPv6Address = if ($ipv6) { $ipv6.Address } else { $null }
        }
    }
}
