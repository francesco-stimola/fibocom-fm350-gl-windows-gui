# eSIM: lpac's command lines and answers, the bridge that carries its APDUs to the eUICC, and lpac
# run to its end. Facts and sources: docs/AT-COMMANDS.md section 8; design: docs/ARCHITECTURE.md
# -> eSIM.
#
# lpac (an external program) speaks SGP.22 to the eUICC. With its 'stdio' APDU backend it hands
# every APDU to the app, which carries it with AT+CCHO / AT+CGLA / AT+CCHC on the AT channel the
# worker owns (invariant 1): lpac never touches the modem. The translation is pure; the process
# around it is thin, and works on any AT channel, whatever transport is under it.

# Where lpac is, below the app's folder: the one place that names it.
$script:LpacRelativePath = 'lpac\lpac.exe'

# lpac's settings for every run (AT-COMMANDS section 8), named in full: unset, lpac picks backends
# of its own - one opens the COM port itself. 120-byte segments make APDUs of 125 bytes at most,
# below the 131 the device carried intact.
$script:LpacEnvironment = [ordered]@{
    LPAC_APDU             = 'stdio'
    LPAC_HTTP             = 'curl'
    LPAC_CUSTOM_ES10X_MSS = '120'
}

# Variables of lpac's and its library's taken out of what lpac inherits: the user's environment
# reaches the elevated app's children, and one of them could name another ISD-R, another backend,
# or debug output carrying the APDUs.
$script:LpacEnvironmentPrefixes = @('LPAC_', 'LIBEUICC_', 'AT_DEVICE')

# The longest command APDU carried: a short APDU's header, 255 bytes of data, and Le.
$script:LpacMaxApduBytes = 261

# lpac writes its channel's number into the class byte's low four bits.
$script:LpacMaxChannel = 15

# The longest nickname, in UTF-8 bytes: SGP.22's UTF8String (SIZE(0..64)), counted the strict way.
$script:EsimMaxNicknameBytes = 64

function Get-LpacPath {
    <#
    .SYNOPSIS
        Returns where lpac.exe is: in the 'lpac' folder beside the app's modules.
    .DESCRIPTION
        The one place that names lpac's path. The installer copies the folder with the rest of the
        app, under Program Files, where only administrators can write (invariant 10); no setting
        names it. Returns the path whether the file is there or not.
    .EXAMPLE
        Test-Path -LiteralPath (Get-LpacPath)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath $script:LpacRelativePath
}

function Get-LpacField {
    # A property of a parsed JSON object, or $null when it has none.
    param([object] $Object, [string] $Name)

    if ($null -ne $Object -and $Object -is [System.Management.Automation.PSCustomObject] -and $Object.PSObject.Properties[$Name]) {
        $Object.$Name
    }
}

function Test-HexText {
    # Whether a text is whole bytes in hexadecimal, at least -MinBytes and at most -MaxBytes.
    param([string] $Text, [int] $MinBytes = 1, [int] $MaxBytes = [int]::MaxValue)

    $Text -match '^(?:[0-9A-Fa-f]{2})+$' -and $Text.Length / 2 -ge $MinBytes -and $Text.Length / 2 -le $MaxBytes
}

function ConvertFrom-LpacLine {
    <#
    .SYNOPSIS
        Reads one line of lpac's output: a request for the eUICC, its progress, or its result.
    .DESCRIPTION
        lpac writes one JSON object per line (AT-COMMANDS section 8). Returns Kind and what that
        kind carries:
        - 'Apdu': Function ('connect', 'disconnect', 'logic_channel_open',
          'logic_channel_close', 'transmit') and Parameter (hexadecimal in upper case, or $null).
        - 'Http': Url - a request for the network, which lpac sends only with its 'stdio' HTTP
          backend.
        - 'Progress': Step, the payload's message. Its data is left out: it can hold the
          profile's ICCID.
        - 'Result': Code (0: success), Message, Data (the payload's data as parsed: an object, a
          list, a string, or $null).
        - 'Other': anything else - another type, a line that is not a JSON object.
    .EXAMPLE
        ConvertFrom-LpacLine -Line '{"type":"apdu","payload":{"func":"connect","param":null}}'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Line
    )

    $other = [pscustomobject]@{ Kind = 'Other' }
    $text = $Line.Trim()
    if (-not $text.StartsWith('{')) {
        return $other
    }
    try {
        $json = ConvertFrom-Json -InputObject $text -DateKind String -Depth 32 -ErrorAction Stop
    }
    catch {
        return $other
    }
    $type = Get-LpacField -Object $json -Name 'type'
    $payload = Get-LpacField -Object $json -Name 'payload'
    if ($type -isnot [string] -or $payload -isnot [System.Management.Automation.PSCustomObject]) {
        return $other
    }
    switch ($type) {
        'apdu' {
            $function = Get-LpacField -Object $payload -Name 'func'
            if ($function -isnot [string]) {
                return $other
            }
            $parameter = Get-LpacField -Object $payload -Name 'param'
            [pscustomobject]@{
                Kind      = 'Apdu'
                Function  = $function
                Parameter = if ($parameter -is [string]) { $parameter.ToUpperInvariant() } else { $null }
            }
        }
        'http' {
            [pscustomobject]@{ Kind = 'Http'; Url = [string](Get-LpacField -Object $payload -Name 'url') }
        }
        { $_ -in 'lpa', 'progress' } {
            $code = Get-LpacField -Object $payload -Name 'code'
            if ($code -isnot [long] -and $code -isnot [int] -and $code -isnot [double]) {
                return $other
            }
            $message = Get-LpacField -Object $payload -Name 'message'
            if ($type -eq 'progress') {
                [pscustomobject]@{ Kind = 'Progress'; Step = [string]$message }
            }
            else {
                [pscustomobject]@{ Kind = 'Result'; Code = [int]$code; Message = [string]$message; Data = Get-LpacField -Object $payload -Name 'data' }
            }
        }
        default { $other }
    }
}

function New-LpacBridge {
    <#
    .SYNOPSIS
        Starts the bridge's state for one run of lpac: no channel open.
    .DESCRIPTION
        Channels lists the logical channels lpac has open, each as Channel (the number lpac was
        given) and Session (the modem's session ID). A session the modem opened that lpac could
        not be given a number for has Channel $null: closed at the end of the run.
    .EXAMPLE
        $bridge = New-LpacBridge
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{ Channels = [object[]]@() }
}

function Get-LpacApduAnswer {
    # An answer for lpac: its ecode, and the response APDU in hexadecimal or $null.
    param([int] $ECode, [string] $Data)

    [pscustomobject]@{ ECode = $ECode; Data = if ($Data) { $Data } else { $null } }
}

function Resolve-LpacApduRequest {
    <#
    .SYNOPSIS
        Decides how to carry one of lpac's APDU requests: the AT command to send, or the answer
        to give at once.
    .DESCRIPTION
        A pure decision (ARCHITECTURE -> eSIM). -Request is ConvertFrom-LpacLine's, of kind
        'Apdu'; -Bridge is New-LpacBridge's, or the Bridge that Resolve-LpacApduAnswer returned
        last. Returns Command - the AT command to send; its answer then goes to
        Resolve-LpacApduAnswer - or Answer (ECode, Data), given to lpac at once:
        - connect, disconnect: 0. The AT port is the worker's, open already.
        - logic_channel_open, the AID as parameter: AT+CCHO="<AID>".
        - logic_channel_close: AT+CCHC=<session> for a channel the bridge opened; 0 for another.
        - transmit: AT+CGLA=<session>,<length>,"<APDU>" (the length in hexadecimal characters),
          on the channel the class byte's low four bits name - lpac writes its channel there -,
          or on the only one open; -1 with none, or several and none named.
        - a parameter that is not what the function takes, an APDU longer than a short APDU
          (261 bytes), or another function: -1.
    .EXAMPLE
        Resolve-LpacApduRequest -Request (ConvertFrom-LpacLine -Line $line) -Bridge $bridge
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Request,

        [Parameter(Mandatory)]
        [object] $Bridge
    )

    $answer = { param($code) [pscustomobject]@{ Command = $null; Answer = (Get-LpacApduAnswer -ECode $code) } }
    $command = { param($text) [pscustomobject]@{ Command = $text; Answer = $null } }
    $parameter = [string]$Request.Parameter
    $open = @($Bridge.Channels | Where-Object { $null -ne $_.Channel })
    switch ($Request.Function) {
        { $_ -in 'connect', 'disconnect' } {
            return & $answer 0
        }
        'logic_channel_open' {
            # An AID is 5 to 16 bytes (ISO/IEC 7816-4); the ISD-R's is 16.
            if (-not (Test-HexText -Text $parameter -MinBytes 5 -MaxBytes 16)) {
                return & $answer -1
            }
            return & $command "AT+CCHO=`"$parameter`""
        }
        'logic_channel_close' {
            if (-not (Test-HexText -Text $parameter -MinBytes 1 -MaxBytes 1)) {
                return & $answer -1
            }
            $number = [Convert]::ToInt32($parameter, 16)
            $known = @($open | Where-Object Channel -EQ $number) | Select-Object -First 1
            if (-not $known) {
                return & $answer 0
            }
            return & $command "AT+CCHC=$($known.Session)"
        }
        'transmit' {
            # A command APDU has its four header bytes at least.
            if (-not (Test-HexText -Text $parameter -MinBytes 4 -MaxBytes $script:LpacMaxApduBytes)) {
                return & $answer -1
            }
            $named = [Convert]::ToInt32($parameter.Substring(0, 2), 16) -band 0x0F
            $target = @($open | Where-Object Channel -EQ $named) | Select-Object -First 1
            if (-not $target -and $open.Count -eq 1) {
                $target = $open[0]
            }
            if (-not $target) {
                return & $answer -1
            }
            return & $command "AT+CGLA=$($target.Session),$($parameter.Length),`"$parameter`""
        }
        default {
            return & $answer -1
        }
    }
}

function Resolve-LpacApduAnswer {
    <#
    .SYNOPSIS
        Turns the modem's answer to a request's AT command into lpac's answer, and the bridge's
        new state.
    .DESCRIPTION
        A pure function. -Request is the request Resolve-LpacApduRequest gave a Command for;
        -Response is Invoke-AtCommand's answer to it (Status, Lines). Returns Answer (ECode,
        Data) and Bridge, a new state - the one given is left as it is:
        - logic_channel_open: the session ID the modem answered (ConvertFrom-AtLogicalChannel)
          gets the lowest channel number free from 1 to 15, which lpac is given; -1 without a
          session ID. A session with no number free stays in the bridge, to be closed.
        - logic_channel_close: 0 whatever the answer - lpac reads none. The channel leaves the
          bridge when the modem answered: OK, or an error, which it gives for a channel the SIM
          closed already (a profile switch resets the SIM, AT-COMMANDS section 8). After a
          timeout or a lost port it stays, to be closed at the end of the run.
        - transmit: 0 and the response APDU, status word included (ConvertFrom-AtGenericAccess);
          -1 when there is none.
    .EXAMPLE
        $next = Resolve-LpacApduAnswer -Request $request -Bridge $bridge -Response $answer
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Request,

        [Parameter(Mandatory)]
        [object] $Bridge,

        [Parameter(Mandatory)]
        [object] $Response
    )

    $channels = @($Bridge.Channels)
    $result = {
        param($code, $data, $list)
        [pscustomobject]@{ Answer = (Get-LpacApduAnswer -ECode $code -Data $data); Bridge = [pscustomobject]@{ Channels = [object[]]@($list) } }
    }
    switch ($Request.Function) {
        'logic_channel_open' {
            $session = if ($Response.Status -eq 'OK') { ConvertFrom-AtLogicalChannel -Lines $Response.Lines } else { $null }
            if ($null -eq $session) {
                return & $result -1 $null $channels
            }
            $used = @($channels | Where-Object { $null -ne $_.Channel } | ForEach-Object Channel)
            $free = @(1..$script:LpacMaxChannel | Where-Object { $_ -notin $used }) | Select-Object -First 1
            $entry = [pscustomobject]@{ Channel = $free; Session = $session }
            return & $result $(if ($null -ne $free) { $free } else { -1 }) $null (@($channels) + $entry)
        }
        'logic_channel_close' {
            $number = [Convert]::ToInt32([string]$Request.Parameter, 16)
            $answered = $Response.Status -notin 'Timeout', 'PortLost'
            $left = @($channels | Where-Object { -not $answered -or $_.Channel -ne $number })
            return & $result 0 $null $left
        }
        'transmit' {
            $data = if ($Response.Status -eq 'OK') { ConvertFrom-AtGenericAccess -Lines $Response.Lines } else { $null }
            return & $result $(if ($data) { 0 } else { -1 }) $data $channels
        }
        default {
            return & $result -1 $null $channels
        }
    }
}

function ConvertTo-LpacAnswerLine {
    <#
    .SYNOPSIS
        Writes an answer for lpac as the line its standard input takes.
    .DESCRIPTION
        {"type":"apdu","payload":{"ecode":<ECode>,"data":"<Data>"}}, data left out when there is
        none (AT-COMMANDS section 8). No line end: the caller adds it.
    .EXAMPLE
        ConvertTo-LpacAnswerLine -Answer (Resolve-LpacApduAnswer ...).Answer
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Answer
    )

    $payload = [ordered]@{ ecode = [int]$Answer.ECode }
    if ($Answer.Data) {
        $payload['data'] = [string]$Answer.Data
    }
    [ordered]@{ type = 'apdu'; payload = $payload } | ConvertTo-Json -Compress -Depth 3
}

function ConvertFrom-AtLogicalChannel {
    <#
    .SYNOPSIS
        Reads the session ID from the answer to AT+CCHO.
    .DESCRIPTION
        27.007 answers the session ID alone on its line, and so does the FM350 (AT-COMMANDS
        section 8); a '+CCHO: <n>' line is read too. Returns the ID, or $null.
    .EXAMPLE
        ConvertFrom-AtLogicalChannel -Lines '1'
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($line in $Lines) {
        if ($line -match '^\s*(?:\+CCHO\s*:\s*)?(\d{1,9})\s*$') {
            return [int]$Matches[1]
        }
    }
}

function ConvertFrom-AtGenericAccess {
    <#
    .SYNOPSIS
        Reads the response APDU from the answer to AT+CGLA.
    .DESCRIPTION
        '+CGLA: <length>,"<response>"' (AT-COMMANDS section 8): the length counts hexadecimal
        characters, and the response ends with its status word. Returns the response in upper
        case - two bytes at least, its length as the modem says -, or $null.
    .EXAMPLE
        ConvertFrom-AtGenericAccess -Lines '+CGLA: 4,"9000"'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($line in $Lines) {
        if ($line -match '^\s*\+CGLA\s*:\s*(\d{1,6})\s*,\s*"?([0-9A-Fa-f]*)"?\s*$') {
            $hex = $Matches[2]
            if ([int]$Matches[1] -eq $hex.Length -and (Test-HexText -Text $hex -MinBytes 2)) {
                return $hex.ToUpperInvariant()
            }
            return $null
        }
    }
}

function ConvertFrom-AtSimSlot {
    <#
    .SYNOPSIS
        Reads which SIM slot is in use from the answer to AT+GTDUALSIM?.
    .DESCRIPTION
        '+GTDUALSIM : <slot>, "<name>", "<service>"', with a blank before the colon on the FM350
        (AT-COMMANDS section 8): slot 0 is SIM1, slot 1 SIM2 - on our module, its eUICC. Returns
        Slot, Name ('SUB1', 'SUB2') and Service (the modem's word for the network it has:
        'NR', 'LTE', 'NO SERVICE'...), or $null.
    .EXAMPLE
        ConvertFrom-AtSimSlot -Lines '+GTDUALSIM : 1, "SUB2", "NO SERVICE"'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($line in $Lines) {
        if ($line -match '^\s*\+GTDUALSIM\s*:\s*(\d)\s*(?:,\s*"([^"]*)"\s*(?:,\s*"([^"]*)")?)?') {
            return [pscustomobject]@{
                Slot    = [int]$Matches[1]
                Name    = if ($Matches[2]) { $Matches[2] } else { $null }
                Service = if ($Matches[3]) { $Matches[3] } else { $null }
            }
        }
    }
}

function ConvertFrom-AtSimType {
    <#
    .SYNOPSIS
        Reads the kind of SIM in use from the answer to AT+SIMTYPE?.
    .DESCRIPTION
        '+SIMTYPE: 0' is a physical SIM (USIM), '+SIMTYPE: 1' an eSIM (AT-COMMANDS section 8).
        Returns 'Usim', 'Esim', or $null - another value, or no answer (the modem answers an
        error without a SIM).
    .EXAMPLE
        ConvertFrom-AtSimType -Lines '+SIMTYPE: 1'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Lines
    )

    foreach ($line in $Lines) {
        if ($line -match '^\s*\+SIMTYPE\s*:\s*([01])\s*$') {
            return $(if ($Matches[1] -eq '1') { 'Esim' } else { 'Usim' })
        }
    }
}

function ConvertFrom-EsimActivationCode {
    <#
    .SYNOPSIS
        Reads an activation code - what a provider's QR code holds - and checks it.
    .DESCRIPTION
        'LPA:1$<SM-DP+ address>$<matching ID>[$<SM-DP+ OID>[$<confirmation code required>]]'
        (SGP.22 section 4.1, as lpac reads it: AT-COMMANDS section 8); 'LPA:' may be left out, in
        any case. Returns Code - the code as lpac takes it, from 'LPA:' on -, Address,
        ConfirmationRequired, and Problem: $null, or 'Empty', 'Format' (a format other than 1, or
        too few fields), 'Address' (not a host name), 'MatchingId' (a character other than a
        letter, a digit or '-'). An activation code is a secret: never logged.
    .EXAMPLE
        ConvertFrom-EsimActivationCode -Text 'LPA:1$smdp.example.com$ABC-123'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $outcome = {
        param($problem, $fields)
        [pscustomobject]@{
            Code                 = if ($problem) { $null } else { 'LPA:' + ($fields -join '$') }
            Address              = if ($fields.Count -gt 1) { $fields[1] } else { $null }
            ConfirmationRequired = $fields.Count -gt 4 -and $fields[4] -eq '1'
            Problem              = $problem
        }
    }
    $body = $Text.Trim()
    if ($body -match '^(?i)LPA:') {
        $body = $body.Substring(4)
    }
    $fields = [string[]]@($body.Split('$'))
    if (-not $body) {
        return & $outcome 'Empty' ([string[]]@())
    }
    if ($fields[0] -ne '1' -or $fields.Count -lt 3) {
        return & $outcome 'Format' $fields
    }
    # A host name: lpac puts it in https://<address>/... as it is.
    if ($fields[1] -notmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$') {
        return & $outcome 'Address' $fields
    }
    if ($fields[2] -notmatch '^[A-Za-z0-9-]*$') {
        return & $outcome 'MatchingId' $fields
    }
    & $outcome $null $fields
}

function Get-LpacArgument {
    <#
    .SYNOPSIS
        Builds lpac's command line for one operation, as a list of arguments.
    .DESCRIPTION
        A pure function (AT-COMMANDS section 8, commands used):
        - ChipInfo: chip info. ProfileList: profile list.
        - EnableProfile, DisableProfile: profile enable|disable <ISD-P AID> 1 - the refresh flag
          always given: lpac's default is none, and the modem resets the SIM on the refresh.
        - SetNickname: profile nickname <ICCID> [<nickname>]; none clears it. At most 64 bytes
          of UTF-8, no control character.
        - DeleteProfile: profile delete <ISD-P AID>.
        - DownloadProfile: profile download -a <activation code> [-c <confirmation code>]; never
          -p (a preview read from standard input, which the APDUs use) nor -i (the IMEI).
        - ListNotifications: notification list. ProcessNotifications: notification process -a
          -r - each sent, then removed from the eUICC.
        chip purge has no operation. Each argument goes as one: the caller passes them in a list
        (ProcessStartInfo.ArgumentList), never joined into one command line. Throws on a value
        an operation can't take.
    .EXAMPLE
        Get-LpacArgument -Operation EnableProfile -ProfileId 'A0000005591010FFFFFFFF8900001000'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ChipInfo', 'ProfileList', 'EnableProfile', 'DisableProfile', 'SetNickname', 'DeleteProfile', 'DownloadProfile',
            'ListNotifications', 'ProcessNotifications')]
        [string] $Operation,

        # An ISD-P AID (enable, disable, delete) or an ICCID (nickname).
        [string] $ProfileId,

        [AllowEmptyString()]
        [string] $Nickname = '',

        [string] $ActivationCode,

        [string] $ConfirmationCode
    )

    $aid = {
        if ($ProfileId -notmatch '^[0-9A-Fa-f]{32}$') {
            throw [System.ArgumentException]::new('An ISD-P AID is 32 hexadecimal characters.', 'ProfileId')
        }
        $ProfileId.ToUpperInvariant()
    }
    switch ($Operation) {
        'ChipInfo' { return [string[]]@('chip', 'info') }
        'ProfileList' { return [string[]]@('profile', 'list') }
        'EnableProfile' { return [string[]]@('profile', 'enable', (& $aid), '1') }
        'DisableProfile' { return [string[]]@('profile', 'disable', (& $aid), '1') }
        'DeleteProfile' { return [string[]]@('profile', 'delete', (& $aid)) }
        'SetNickname' {
            if ($ProfileId -notmatch '^[0-9]{18,20}[Ff]?$') {
                throw [System.ArgumentException]::new('An ICCID is 18 to 20 digits.', 'ProfileId')
            }
            if ([System.Text.Encoding]::UTF8.GetByteCount($Nickname) -gt $script:EsimMaxNicknameBytes -or $Nickname -match '\p{C}') {
                throw [System.ArgumentException]::new("A nickname is $($script:EsimMaxNicknameBytes) bytes of UTF-8 at most, without control characters.", 'Nickname')
            }
            if ($Nickname) {
                return [string[]]@('profile', 'nickname', $ProfileId, $Nickname)
            }
            return [string[]]@('profile', 'nickname', $ProfileId)
        }
        'DownloadProfile' {
            $code = ConvertFrom-EsimActivationCode -Text ([string]$ActivationCode)
            if ($code.Problem) {
                throw [System.ArgumentException]::new("Not an activation code ($($code.Problem)).", 'ActivationCode')
            }
            $arguments = [System.Collections.Generic.List[string]]::new()
            $arguments.AddRange([string[]]@('profile', 'download', '-a', $code.Code))
            if ($ConfirmationCode) {
                if ($ConfirmationCode -match '\p{C}') {
                    throw [System.ArgumentException]::new('A confirmation code has no control characters.', 'ConfirmationCode')
                }
                $arguments.AddRange([string[]]@('-c', $ConfirmationCode))
            }
            return [string[]]$arguments
        }
        'ListNotifications' { return [string[]]@('notification', 'list') }
        'ProcessNotifications' { return [string[]]@('notification', 'process', '-a', '-r') }
    }
}

function ConvertFrom-LpacProfileList {
    <#
    .SYNOPSIS
        Reads the profiles from the data of 'profile list'.
    .DESCRIPTION
        Returns one object per profile (AT-COMMANDS section 8): Aid (the ISD-P's, upper case),
        Iccid - an identifier: the worker keeps it, no snapshot carries it -, State ('Enabled',
        'Disabled' or 'Unknown'), Nickname, Provider, Name, Class ('Test', 'Provisioning',
        'Operational' or 'Unknown'). An entry without its AID is left out.
    .EXAMPLE
        ConvertFrom-LpacProfileList -Data $result.Data
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Data
    )

    foreach ($entry in @($Data)) {
        $aid = Get-LpacField -Object $entry -Name 'isdpAid'
        if ($aid -isnot [string] -or $aid -notmatch '^[0-9A-Fa-f]{10,32}$') {
            continue
        }
        $state = switch ([string](Get-LpacField -Object $entry -Name 'profileState')) { 'enabled' { 'Enabled' } 'disabled' { 'Disabled' } default { 'Unknown' } }
        $class = switch ([string](Get-LpacField -Object $entry -Name 'profileClass')) {
            'test' { 'Test' } 'provisioning' { 'Provisioning' } 'operational' { 'Operational' } default { 'Unknown' }
        }
        $text = { param($name) $value = Get-LpacField -Object $entry -Name $name; if ($value -is [string] -and $value) { $value } else { $null } }
        [pscustomobject]@{
            Aid      = $aid.ToUpperInvariant()
            Iccid    = & $text 'iccid'
            State    = $state
            Nickname = & $text 'profileNickname'
            Provider = & $text 'serviceProviderName'
            Name     = & $text 'profileName'
            Class    = $class
        }
    }
}

function ConvertFrom-LpacChipInfo {
    <#
    .SYNOPSIS
        Reads the eUICC's facts from the data of 'chip info'.
    .DESCRIPTION
        Returns Eid - an identifier: the worker keeps it, no snapshot carries it -, DefaultAddress
        (the default SM-DP+), Specification (the SGP.22 version, EUICCInfo2's svn), Firmware,
        FreeMemory (free non-volatile memory, in bytes) and CiKeys (the CIs it trusts to verify,
        upper case); $null for what the data doesn't hold.
    .EXAMPLE
        ConvertFrom-LpacChipInfo -Data $result.Data
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Data
    )

    $addresses = Get-LpacField -Object $Data -Name 'EuiccConfiguredAddresses'
    $info = Get-LpacField -Object $Data -Name 'EUICCInfo2'
    $resources = Get-LpacField -Object $info -Name 'extCardResource'
    $free = Get-LpacField -Object $resources -Name 'freeNonVolatileMemory'
    $text = { param($object, $name) $value = Get-LpacField -Object $object -Name $name; if ($value -is [string] -and $value) { $value } else { $null } }
    [pscustomobject]@{
        Eid            = & $text $Data 'eidValue'
        DefaultAddress = & $text $addresses 'defaultDpAddress'
        Specification  = & $text $info 'svn'
        Firmware       = & $text $info 'euiccFirmwareVer'
        FreeMemory     = if ($free -is [long] -or $free -is [int] -or $free -is [double]) { [long]$free } else { $null }
        CiKeys         = [string[]]@(Get-LpacField -Object $info -Name 'euiccCiPKIdListForVerification' | Where-Object { $_ -is [string] } | ForEach-Object { $_.ToUpperInvariant() })
    }
}

function ConvertFrom-LpacNotificationList {
    <#
    .SYNOPSIS
        Reads the eUICC's pending notifications from the data of 'notification list'.
    .DESCRIPTION
        Returns one object per notification: Sequence, Operation ('install', 'enable',
        'disable', 'delete' as lpac names them) and Address (the server it goes to). The ICCID
        it names is left out.
    .EXAMPLE
        ConvertFrom-LpacNotificationList -Data $result.Data
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Data
    )

    foreach ($entry in @($Data)) {
        $sequence = Get-LpacField -Object $entry -Name 'seqNumber'
        if ($sequence -isnot [long] -and $sequence -isnot [int] -and $sequence -isnot [double]) {
            continue
        }
        [pscustomobject]@{
            Sequence  = [long]$sequence
            Operation = [string](Get-LpacField -Object $entry -Name 'profileManagementOperation')
            Address   = [string](Get-LpacField -Object $entry -Name 'notificationAddress')
        }
    }
}

# lpac as a child process, shaped for Invoke-LpacOperation: ReadLine, WriteLine, Ended, Stop,
# Dispose, ExitCode (a simulated lpac has the same shape). Its standard output is read one line
# at a time, a read never waiting longer than asked: the worker's heartbeat goes on. Its standard
# error is read to its end in the background, unseen: lpac writes there only what its debug
# variables ask, which are taken out of its environment.
[NoRunspaceAffinity()]
class LpacProcess {
    # Its output is over: it closed it, or ended.
    [bool] $Ended = $false
    hidden [System.Diagnostics.Process] $Process
    hidden [System.Threading.Tasks.Task[string]] $Pending
    hidden [System.Threading.Tasks.Task[string]] $Errors

    LpacProcess([string] $path, [string[]] $arguments, [System.Collections.IDictionary] $environment, [string[]] $removed) {
        $info = [System.Diagnostics.ProcessStartInfo]::new($path)
        foreach ($argument in $arguments) {
            $info.ArgumentList.Add($argument)
        }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $info.StandardInputEncoding = $utf8
        $info.StandardOutputEncoding = $utf8
        $info.StandardErrorEncoding = $utf8
        $info.WorkingDirectory = [System.IO.Path]::GetDirectoryName($path)
        foreach ($name in @($info.Environment.Keys)) {
            foreach ($prefix in $removed) {
                if ($name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    [void]$info.Environment.Remove($name)
                    break
                }
            }
        }
        foreach ($name in $environment.Keys) {
            $info.Environment[[string]$name] = [string]$environment[$name]
        }
        $this.Process = [System.Diagnostics.Process]::Start($info)
        $this.Errors = $this.Process.StandardError.ReadToEndAsync()
    }

    # The next line lpac wrote, or $null when none came within $timeoutMs - or its output is
    # over (Ended).
    [string] ReadLine([int] $timeoutMs) {
        if ($this.Ended) {
            return $null
        }
        if (-not $this.Pending) {
            $this.Pending = $this.Process.StandardOutput.ReadLineAsync()
        }
        try {
            if (-not $this.Pending.Wait([Math]::Max(0, $timeoutMs))) {
                return $null
            }
            $line = $this.Pending.Result
        }
        catch {
            $line = $null
        }
        $this.Pending = $null
        if ($null -eq $line) {
            $this.Ended = $true
        }
        return $line
    }

    # A line for lpac's standard input; lost when lpac has ended.
    [void] WriteLine([string] $text) {
        try {
            $this.Process.StandardInput.Write($text + "`n")
            $this.Process.StandardInput.Flush()
        }
        catch [System.IO.IOException] {
            $this.Ended = $true
        }
    }

    # Its exit code once it has ended within $timeoutMs, or $null.
    [Nullable[int]] ExitCode([int] $timeoutMs) {
        if ($this.Process.WaitForExit([Math]::Max(0, $timeoutMs))) {
            return $this.Process.ExitCode
        }
        return $null
    }

    # Ends it, if it is still running.
    [void] Stop() {
        try {
            if (-not $this.Process.HasExited) {
                $this.Process.Kill($true)
            }
        }
        catch [System.InvalidOperationException] {
            Write-Debug 'lpac had ended already.'
        }
        $this.Ended = $true
    }

    [void] Dispose() {
        $this.Stop()
        [void]$this.Process.WaitForExit(5000)
        $this.Process.Dispose()
    }
}

function Start-LpacProcess {
    <#
    .SYNOPSIS
        Starts lpac with its stdio APDU backend, for Invoke-LpacOperation.
    .DESCRIPTION
        Runs -Path (Get-LpacPath by default) with -Argument (Get-LpacArgument's), each argument
        passed as one, no window, its standard input and output redirected, and its own settings
        in its environment (AT-COMMANDS section 8) - lpac's and its library's other variables
        taken out. Returns the running process, which Invoke-LpacOperation owns and disposes.
        The arguments can hold an activation code: never logged.
    .EXAMPLE
        $lpac = Start-LpacProcess -Argument (Get-LpacArgument -Operation ChipInfo)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [string] $Path = (Get-LpacPath),

        [Parameter(Mandatory)]
        [string[]] $Argument
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new('lpac is not installed with the app.', $Path)
    }
    if ($PSCmdlet.ShouldProcess($Path, "Start lpac $($Argument[0]) $($Argument[1])")) {
        [LpacProcess]::new($Path, $Argument, $script:LpacEnvironment, $script:LpacEnvironmentPrefixes)
    }
}

function Invoke-LpacOperation {
    <#
    .SYNOPSIS
        Runs lpac to its end, carrying its APDUs to the eUICC over the AT channel.
    .DESCRIPTION
        -Lpac is a running lpac: Start-LpacProcess's, or a simulated one of the same shape
        (ReadLine, WriteLine, Ended, ExitCode, Stop, Dispose). This function owns it from here:
        it is stopped and disposed whatever happens. Each request lpac writes is translated
        (Resolve-LpacApduRequest), carried on -Channel, and answered (Resolve-LpacApduAnswer);
        each step of its progress noted; its result kept. A request for the network is answered
        as a failure: the app runs lpac with its own HTTP backend.

        It ends when lpac's output ends, or after -TimeoutMs (lpac stopped), or when the AT port
        is lost (likewise). Channels left open - lpac stopped, a close that went unanswered - are
        closed at the end, on a port still there. -Beat runs between reads, at least once a
        second: the worker's heartbeat.

        Returns Outcome - 'Done' (lpac gave its result: Code 0 or not), 'NoResult' (it ended
        without one), 'Timeout' or 'PortLost' -, Code, Message and Data (lpac's result; on a
        failure Data is lpac's short reason), Steps (the progress, in order), Requests (how many
        APDU requests) and ElapsedMs. Nothing of the APDUs or of lpac's lines is logged here.
    .EXAMPLE
        $run = Invoke-LpacOperation -Channel $channel -Lpac (Start-LpacProcess -Argument (Get-LpacArgument -Operation ProfileList))
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AtChannel] $Channel,

        [Parameter(Mandatory)]
        [object] $Lpac,

        [ValidateRange(1, [int]::MaxValue)]
        [int] $TimeoutMs = 300000,

        [scriptblock] $Beat = {}
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $bridge = New-LpacBridge
    $steps = [System.Collections.Generic.List[string]]::new()
    $result = $null
    $requests = 0
    $outcome = $null
    try {
        while (-not $outcome) {
            $left = $TimeoutMs - $clock.ElapsedMilliseconds
            if ($left -le 0) {
                $outcome = 'Timeout'
                break
            }
            & $Beat
            # A class method typed [string] returns $null as '': either means no line.
            $line = $Lpac.ReadLine([int][Math]::Min($left, 1000))
            if (-not $line) {
                if ($Lpac.Ended) {
                    $outcome = if ($result) { 'Done' } else { 'NoResult' }
                }
                continue
            }
            $read = ConvertFrom-LpacLine -Line $line
            switch ($read.Kind) {
                'Apdu' {
                    $requests++
                    $decision = Resolve-LpacApduRequest -Request $read -Bridge $bridge
                    $answer = $decision.Answer
                    if ($decision.Command) {
                        $response = Invoke-AtCommand -Channel $Channel -Command $decision.Command
                        $next = Resolve-LpacApduAnswer -Request $read -Bridge $bridge -Response $response
                        $bridge = $next.Bridge
                        $answer = $next.Answer
                        if ($response.Status -eq 'PortLost') {
                            $outcome = 'PortLost'
                        }
                    }
                    if (-not $outcome) {
                        $Lpac.WriteLine((ConvertTo-LpacAnswerLine -Answer $answer))
                    }
                }
                'Http' {
                    $Lpac.WriteLine('{"type":"http","payload":{"rcode":500,"rx":""}}')
                }
                'Progress' {
                    $steps.Add($read.Step)
                }
                'Result' {
                    $result = $read
                }
            }
        }
    }
    finally {
        $Lpac.Dispose()
        # Channels lpac left open, closed on a port still there.
        foreach ($entry in @($bridge.Channels)) {
            if ($Channel.State -eq 'Open') {
                [void](Invoke-AtCommand -Channel $Channel -Command "AT+CCHC=$($entry.Session)")
            }
        }
    }
    [pscustomobject]@{
        Outcome   = $outcome
        Code      = if ($result) { $result.Code } else { $null }
        Message   = if ($result) { $result.Message } else { $null }
        Data      = if ($result) { $result.Data } else { $null }
        Steps     = [string[]]$steps
        Requests  = $requests
        ElapsedMs = $clock.ElapsedMilliseconds
    }
}
