# SMS: the PDU codec - messages read from the modem's storage, decoded; messages to send, encoded
# and split. Written from 3GPP TS 23.040, 23.038, 24.011 and 27.005: docs/AT-COMMANDS.md section 9,
# SMS PDUs. Every function here is pure: hexadecimal text or values in, values out.

# The GSM 7 bit default alphabet and its extension table (23.038 clauses 6.2.1, 6.2.1.1).
$script:GsmAlphabet = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'Data/GsmAlphabet.psd1')
$script:Gsm7Escape = 0x1B
$script:Gsm7Default = [char[]]::new(128)
foreach ($entry in $script:GsmAlphabet.Default) {
    $script:Gsm7Default[$entry.Septet] = [char]$entry.CodePoint
}
$script:Gsm7Extension = [System.Collections.Generic.Dictionary[int, char]]::new()
foreach ($entry in $script:GsmAlphabet.Extension) {
    $script:Gsm7Extension[$entry.Septet] = [char]$entry.CodePoint
}
# Each character the alphabet can carry, and the septets it takes: one, or the escape and one.
$script:Gsm7Septets = [System.Collections.Generic.Dictionary[char, byte[]]]::new()
foreach ($entry in $script:GsmAlphabet.Default) {
    $script:Gsm7Septets[[char]$entry.CodePoint] = [byte[]]@($entry.Septet)
}
foreach ($entry in $script:GsmAlphabet.Extension) {
    if (-not $script:Gsm7Septets.ContainsKey([char]$entry.CodePoint)) {
        $script:Gsm7Septets[[char]$entry.CodePoint] = [byte[]]@($script:Gsm7Escape, $entry.Septet)
    }
}

# Types of number (23.040 clause 9.1.2.5); a reserved one reads as unknown.
$script:SmsNumberTypes = @('Unknown', 'International', 'National', 'NetworkSpecific', 'Subscriber', 'Alphanumeric', 'Abbreviated', 'Unknown')

# What one message, or one part of a long one, carries (23.040 clauses 9.2.3.24.1 and 9.2.2.2): in
# septets for GSM 7-bit, in UTF-16 code units for UCS2. A long message's parts carry a header with
# a one-octet reference (6 octets), which takes 7 septets or 3 code units.
$script:SmsLimits = @{
    Gsm7 = @{ Single = 160; Part = 153 }
    Ucs2 = @{ Single = 70; Part = 67 }
}
$script:SmsMaxParts = 255

function Expand-SmsSeptet {
    # Unpacks -Count septets from -Octets, the first one starting -SkipBits bits into it
    # (23.038 clause 6.1.2.1.1: septets fill the octets from bit 0).
    param([byte[]] $Octets, [int] $Count, [int] $SkipBits = 0)

    $septets = [byte[]]::new($Count)
    for ($i = 0; $i -lt $Count; $i++) {
        $bit = $SkipBits + 7 * $i
        $index = [Math]::Floor($bit / 8)
        $shift = $bit % 8
        $value = [int]$Octets[$index] -shr $shift
        if ($shift -gt 1) {
            $value = $value -bor ([int]$Octets[$index + 1] -shl (8 - $shift))
        }
        $septets[$i] = $value -band 0x7F
    }
    , $septets
}

function Compress-SmsSeptet {
    # Packs septets into octets, after -FillBits zero bits (the fill after a user data header).
    param([byte[]] $Septets, [int] $FillBits = 0)

    $bits = $FillBits + 7 * $Septets.Count
    $octets = [byte[]]::new([Math]::Ceiling($bits / 8))
    for ($i = 0; $i -lt $Septets.Count; $i++) {
        $bit = $FillBits + 7 * $i
        $index = [Math]::Floor($bit / 8)
        $shift = $bit % 8
        $value = [int]$Septets[$i] -shl $shift
        $octets[$index] = $octets[$index] -bor ($value -band 0xFF)
        if ($shift -gt 1) {
            $octets[$index + 1] = $octets[$index + 1] -bor ($value -shr 8)
        }
    }
    , $octets
}

function ConvertFrom-Gsm7Septet {
    # Text from septets of the GSM 7 bit default alphabet: an escaped septet the extension table
    # doesn't hold reads as the default alphabet's character, an escape followed by another escape
    # (a further table, not defined) as a space, and a lone escape at the end as nothing.
    param([byte[]] $Septets)

    $text = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Septets.Count; $i++) {
        $septet = [int]$Septets[$i]
        if ($septet -ne $script:Gsm7Escape) {
            [void]$text.Append($script:Gsm7Default[$septet])
            continue
        }
        $i++
        if ($i -ge $Septets.Count) {
            break
        }
        $escaped = [int]$Septets[$i]
        if ($script:Gsm7Extension.ContainsKey($escaped)) {
            [void]$text.Append($script:Gsm7Extension[$escaped])
        }
        elseif ($escaped -eq $script:Gsm7Escape) {
            [void]$text.Append(' ')
        }
        else {
            [void]$text.Append($script:Gsm7Default[$escaped])
        }
    }
    $text.ToString()
}

function ConvertTo-Gsm7Septet {
    # The septets of a text in the GSM 7 bit default alphabet and its extension table; $null when a
    # character is in neither.
    param([string] $Text)

    $septets = [System.Collections.Generic.List[byte]]::new()
    foreach ($character in $Text.ToCharArray()) {
        if (-not $script:Gsm7Septets.ContainsKey($character)) {
            return $null
        }
        $septets.AddRange($script:Gsm7Septets[$character])
    }
    , $septets.ToArray()
}

function ConvertFrom-SmsSemiOctet {
    # The digits of semi-octets, the first in the low half (23.040 clause 9.1.2.3): 1010 '*',
    # 1011 '#', 1100-1110 'a'-'c'; 1111 is fill and is skipped.
    param([byte[]] $Octets, [int] $Count)

    $digits = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        $octet = [int]$Octets[[Math]::Floor($i / 2)]
        $nibble = if ($i % 2 -eq 0) { $octet -band 0x0F } else { $octet -shr 4 }
        if ($nibble -lt 10) {
            [void]$digits.Append([char](48 + $nibble))
        }
        elseif ($nibble -lt 15) {
            [void]$digits.Append('*#abc'[$nibble - 10])
        }
    }
    $digits.ToString()
}

function Read-SmsOctet {
    # -Count octets of -Octets from -Offset; a PDU that ends too soon is malformed.
    param([byte[]] $Octets, [int] $Offset, [int] $Count)

    if ($Count -lt 0 -or $Offset + $Count -gt $Octets.Count) {
        throw [System.FormatException]::new('The PDU ends too soon.')
    }
    if ($Count -eq 0) {
        return , [byte[]]@()
    }
    , [byte[]]$Octets[$Offset..($Offset + $Count - 1)]
}

function ConvertFrom-SmsAddress {
    # An address field at -Offset (23.040 clause 9.1.2.5; the service centre's, -ServiceCentre,
    # 24.011 clause 8.2.5: its length counts octets). Returns the address - international numbers
    # with '+' -, its type of number, and how many octets the field took.
    param([byte[]] $Octets, [int] $Offset, [switch] $ServiceCentre)

    $length = [int](Read-SmsOctet -Octets $Octets -Offset $Offset -Count 1)[0]
    if ($ServiceCentre) {
        if ($length -eq 0) {
            return [pscustomobject]@{ Address = $null; Type = $null; Size = 1 }
        }
        $valueOctets = $length - 1
    }
    else {
        $valueOctets = [int][Math]::Ceiling($length / 2)
    }
    $typeOfAddress = [int](Read-SmsOctet -Octets $Octets -Offset ($Offset + 1) -Count 1)[0]
    $value = Read-SmsOctet -Octets $Octets -Offset ($Offset + 2) -Count $valueOctets
    $type = $script:SmsNumberTypes[($typeOfAddress -shr 4) -band 0x07]
    $address = if ($type -eq 'Alphanumeric' -and -not $ServiceCentre) {
        ConvertFrom-Gsm7Septet -Septets (Expand-SmsSeptet -Octets $value -Count ([Math]::Floor($length * 4 / 7)))
    }
    else {
        $digits = ConvertFrom-SmsSemiOctet -Octets $value -Count $(if ($ServiceCentre) { 2 * $valueOctets } else { $length })
        if ($type -eq 'International' -and $digits) { "+$digits" } else { $digits }
    }
    [pscustomobject]@{ Address = $address; Type = $type; Size = 2 + $valueOctets }
}

function ConvertTo-SmsAddress {
    # The destination address field of a number: '+' and digits is an international number, digits
    # alone an unknown type, both in the E.164 numbering plan (23.040 clause 9.1.2.5).
    param([string] $Number)

    $international = $Number.StartsWith('+')
    $digits = $Number.TrimStart('+')
    $octets = [System.Collections.Generic.List[byte]]::new()
    $octets.Add($digits.Length)
    $octets.Add($(if ($international) { 0x91 } else { 0x81 }))
    for ($i = 0; $i -lt $digits.Length; $i += 2) {
        $low = [int]$digits[$i] - 48
        $high = if ($i + 1 -lt $digits.Length) { [int]$digits[$i + 1] - 48 } else { 0x0F }
        $octets.Add(($high -shl 4) -bor $low)
    }
    , $octets.ToArray()
}

function ConvertFrom-SmsTimestamp {
    # A time stamp of seven octets (23.040 clause 9.2.3.11): year, month, day, hour, minute, second
    # in swapped semi-octets, then the time zone in quarters of an hour, its sign in bit 3. A digit
    # that is not one reads as 0; the year is taken in 2000-2099. $null for a date that doesn't exist.
    param([byte[]] $Octets, [int] $Offset)

    $field = Read-SmsOctet -Octets $Octets -Offset $Offset -Count 7
    $number = {
        param([int] $octet, [int] $lowMask)
        $low = $octet -band $lowMask
        $high = $octet -shr 4
        (($(if ($low -lt 10) { $low } else { 0 })) * 10) + $(if ($high -lt 10) { $high } else { 0 })
    }
    $values = foreach ($position in 0..5) { & $number $field[$position] 0x0F }
    $quarters = & $number $field[6] 0x07
    $sign = if ($field[6] -band 0x08) { -1 } else { 1 }
    try {
        [DateTimeOffset]::new(2000 + $values[0], $values[1], $values[2], $values[3], $values[4], $values[5], [TimeSpan]::FromMinutes($sign * 15 * $quarters))
    }
    catch [System.ArgumentException] {
        $null
    }
}

function Resolve-SmsDataCoding {
    # The data coding scheme (23.038 clause 4): the alphabet - 'Gsm7', 'Data8', 'Ucs2' -, whether
    # the text is compressed, the message class (0-3, or $null) and a message-waiting indication
    # (Kind - 'Voicemail', 'Fax', 'Email', 'Other' -, Active, Store), or $null. Reserved codings
    # read as GSM 7-bit.
    param([int] $Dcs)

    $group = $Dcs -shr 4
    $alphabet = 'Gsm7'
    $compressed = $false
    $class = $null
    $waiting = $null
    if ($group -le 0x07) {
        $alphabet = @('Gsm7', 'Data8', 'Ucs2', 'Gsm7')[($Dcs -shr 2) -band 0x03]
        $compressed = [bool]($Dcs -band 0x20)
        if ($Dcs -band 0x10) {
            $class = $Dcs -band 0x03
        }
    }
    elseif ($group -in 0x0C, 0x0D, 0x0E) {
        $alphabet = if ($group -eq 0x0E) { 'Ucs2' } else { 'Gsm7' }
        $waiting = [pscustomobject]@{
            Kind   = @('Voicemail', 'Fax', 'Email', 'Other')[$Dcs -band 0x03]
            Active = [bool]($Dcs -band 0x08)
            Store  = $group -ne 0x0C
        }
    }
    elseif ($group -eq 0x0F) {
        $alphabet = if ($Dcs -band 0x04) { 'Data8' } else { 'Gsm7' }
        $class = $Dcs -band 0x03
    }
    [pscustomobject]@{ Alphabet = $alphabet; Compressed = $compressed; Class = $class; Waiting = $waiting }
}

function Resolve-SmsDeliveryOutcome {
    # What a status report's status says (23.040 clause 9.2.3.15): 'Delivered' (transaction
    # completed, 0x00-0x02 and the centre's own 0x10-0x1F), 'Trying' (a temporary error, the centre
    # still trying: 0x20-0x25 and its own 0x30-0x3F), 'Failed' otherwise - reserved values read as
    # "service rejected", which the centre no longer tries.
    param([int] $Status)

    if ($Status -le 0x02 -or ($Status -ge 0x10 -and $Status -le 0x1F)) {
        'Delivered'
    }
    elseif (($Status -ge 0x20 -and $Status -le 0x25) -or ($Status -ge 0x30 -and $Status -le 0x3F)) {
        'Trying'
    }
    else {
        'Failed'
    }
}

function ConvertFrom-SmsUserDataHeader {
    # The information elements of a user data header (23.040 clause 9.2.3.24): the long message's
    # reference, count and part (elements 0x00 and 0x08; ignored when the count or the part number
    # is out of range), and whether a national language table is named (0x24, 0x25). A header whose
    # last element runs past its length is ignored whole; other elements are skipped.
    param([byte[]] $Header)

    $concat = $null
    $national = $false
    $position = 0
    while ($position -lt $Header.Count) {
        if ($position + 1 -ge $Header.Count -or $position + 2 + $Header[$position + 1] -gt $Header.Count) {
            return [pscustomobject]@{ Concat = $null; NationalLanguage = $false }
        }
        $identifier = [int]$Header[$position]
        $length = [int]$Header[$position + 1]
        $data = if ($length) { [byte[]]$Header[($position + 2)..($position + 1 + $length)] } else { [byte[]]@() }
        if (($identifier -eq 0x00 -and $length -eq 3) -or ($identifier -eq 0x08 -and $length -eq 4)) {
            $wide = $identifier -eq 0x08
            $reference = if ($wide) { ([int]$data[0] -shl 8) -bor $data[1] } else { [int]$data[0] }
            $count = [int]$data[$length - 2]
            $part = [int]$data[$length - 1]
            # The last of two such elements counts (clause 9.2.3.24).
            $concat = if ($count -ge 1 -and $part -ge 1 -and $part -le $count) {
                [pscustomobject]@{ Reference = $reference; Wide = $wide; Count = $count; Part = $part }
            }
            else {
                $null
            }
        }
        elseif ($identifier -in 0x24, 0x25) {
            $national = $true
        }
        $position += 2 + $length
    }
    [pscustomobject]@{ Concat = $concat; NationalLanguage = $national }
}

function ConvertFrom-SmsUserData {
    # The user data at -Offset, read by its length (septets or octets, 23.040 clause 9.2.3.16), its
    # header when -HasHeader, and the text by its coding: Content 'Text', 'Binary' (8-bit data, no
    # text) or 'Compressed' (not decoded).
    param([byte[]] $Octets, [int] $Offset, [object] $Coding, [switch] $HasHeader)

    $length = [int](Read-SmsOctet -Octets $Octets -Offset $Offset -Count 1)[0]
    $septets = $Coding.Alphabet -eq 'Gsm7' -and -not $Coding.Compressed
    $size = if ($septets) { [int][Math]::Ceiling($length * 7 / 8) } else { $length }
    $data = Read-SmsOctet -Octets $Octets -Offset ($Offset + 1) -Count $size
    $header = [pscustomobject]@{ Concat = $null; NationalLanguage = $false }
    $headerOctets = 0
    if ($HasHeader -and $data.Count -gt 0) {
        $headerOctets = 1 + $data[0]
        $header = ConvertFrom-SmsUserDataHeader -Header (Read-SmsOctet -Octets $data -Offset 1 -Count ($headerOctets - 1))
    }
    $content = 'Text'
    $text = $null
    if ($Coding.Compressed) {
        $content = 'Compressed'
    }
    elseif ($septets) {
        $headerSeptets = [int][Math]::Ceiling($headerOctets * 8 / 7)
        $count = [Math]::Max(0, $length - $headerSeptets)
        $text = ConvertFrom-Gsm7Septet -Septets (Expand-SmsSeptet -Octets $data -Count $count -SkipBits (7 * $headerSeptets))
    }
    elseif ($Coding.Alphabet -eq 'Ucs2') {
        $body = $data.Count - $headerOctets
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($data, $headerOctets, $body - $body % 2)
    }
    else {
        $content = 'Binary'
    }
    [pscustomobject]@{ Content = $content; Text = $text; Concat = $header.Concat; NationalLanguage = $header.NationalLanguage }
}

function ConvertFrom-SmsPdu {
    <#
    .SYNOPSIS
        Decodes a message PDU as the modem lists it: the service centre's address, then the TPDU.
    .DESCRIPTION
        A pure function, written from 3GPP TS 23.040, 23.038 and 24.011 (docs/AT-COMMANDS.md
        section 9, SMS PDUs). -NoServiceCentre takes a TPDU alone.

        Returns Type - 'Deliver' (a message received), 'Submit' (one stored to send or sent),
        'StatusReport' -, ServiceCentre, Address (the sender, or the recipient of what was sent;
        international numbers with '+', a name for an alphanumeric sender), AddressType, and Problem:
        $null, or 'Malformed' for a PDU that can't be read - then nothing else is filled.
        Messages ('Deliver', 'Submit'): Content ('Text', 'Binary' for 8-bit data, 'Compressed', not
        decoded), Text, Alphabet, Class (0-3 or $null), Waiting (a message-waiting indication, or
        $null), Silent (protocol identifier 0x40: a message never to be shown), Concat (the part of
        a long message: Reference, Wide - a two-octet reference -, Count, Part; or $null) and
        NationalLanguage (a national language table named: read with the default ones).
        'Deliver' adds Time, the service centre's time stamp; 'Submit' and 'StatusReport' add
        Reference, the message reference. 'StatusReport' adds Time, Discharged, Status (the
        number) and Outcome: 'Delivered', 'Trying' (a temporary error, the centre still trying) or
        'Failed'.
    .EXAMPLE
        ConvertFrom-SmsPdu -Pdu '0791...'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Pdu,

        [switch] $NoServiceCentre
    )

    $message = [ordered]@{
        Type             = $null
        ServiceCentre    = $null
        Address          = $null
        AddressType      = $null
        Problem          = $null
        Content          = $null
        Text             = $null
        Alphabet         = $null
        Class            = $null
        Waiting          = $null
        Silent           = $false
        Concat           = $null
        NationalLanguage = $false
        Time             = $null
        Reference        = $null
        Discharged       = $null
        Status           = $null
        Outcome          = $null
    }
    try {
        $octets = [Convert]::FromHexString($Pdu.Trim())
        $offset = 0
        if (-not $NoServiceCentre) {
            $centre = ConvertFrom-SmsAddress -Octets $octets -Offset 0 -ServiceCentre
            $message.ServiceCentre = $centre.Address
            $offset = $centre.Size
        }
        $first = [int](Read-SmsOctet -Octets $octets -Offset $offset -Count 1)[0]
        $offset++
        $type = $first -band 0x03
        if ($type -eq 2) {
            $message.Type = 'StatusReport'
            $message.Reference = [int](Read-SmsOctet -Octets $octets -Offset $offset -Count 1)[0]
            $recipient = ConvertFrom-SmsAddress -Octets $octets -Offset ($offset + 1)
            $message.Address = $recipient.Address
            $message.AddressType = $recipient.Type
            $offset += 1 + $recipient.Size
            $message.Time = ConvertFrom-SmsTimestamp -Octets $octets -Offset $offset
            $message.Discharged = ConvertFrom-SmsTimestamp -Octets $octets -Offset ($offset + 7)
            $status = [int](Read-SmsOctet -Octets $octets -Offset ($offset + 14) -Count 1)[0]
            $message.Status = $status
            $message.Outcome = Resolve-SmsDeliveryOutcome -Status $status
        }
        else {
            $submit = $type -eq 1
            $message.Type = if ($submit) { 'Submit' } else { 'Deliver' }
            if ($submit) {
                $message.Reference = [int](Read-SmsOctet -Octets $octets -Offset $offset -Count 1)[0]
                $offset++
            }
            $address = ConvertFrom-SmsAddress -Octets $octets -Offset $offset
            $message.Address = $address.Address
            $message.AddressType = $address.Type
            $offset += $address.Size
            $protocol = [int](Read-SmsOctet -Octets $octets -Offset $offset -Count 1)[0]
            $coding = Resolve-SmsDataCoding -Dcs ([int](Read-SmsOctet -Octets $octets -Offset ($offset + 1) -Count 1)[0])
            $offset += 2
            if ($submit) {
                # The validity period, by its format in bits 3-4: none, enhanced (7 octets),
                # relative (1), absolute (7).
                $offset += @(0, 7, 1, 7)[($first -shr 3) -band 0x03]
            }
            else {
                $message.Time = ConvertFrom-SmsTimestamp -Octets $octets -Offset $offset
                $offset += 7
            }
            $data = ConvertFrom-SmsUserData -Octets $octets -Offset $offset -Coding $coding -HasHeader:([bool]($first -band 0x40))
            $message.Silent = $protocol -eq 0x40
            $message.Alphabet = $coding.Alphabet
            $message.Class = $coding.Class
            $message.Waiting = $coding.Waiting
            $message.Content = $data.Content
            $message.Text = $data.Text
            $message.Concat = $data.Concat
            $message.NationalLanguage = $data.NationalLanguage
        }
    }
    catch {
        foreach ($key in @($message.Keys)) {
            $message[$key] = if ($key -in 'Silent', 'NationalLanguage') { $false } else { $null }
        }
        $message.Problem = 'Malformed'
    }
    [pscustomobject]$message
}

function Split-SmsText {
    # The text cut into the parts of a message (23.040 clause 9.2.3.24.1): in GSM 7-bit when every
    # character is in the alphabet, else in UCS2. Returns Alphabet, Units (septets or UTF-16 code
    # units in all), PerPart and Parts - each a list of the part's septets, or of its code units -;
    # one part when the text fits a single message. An escaped character is never split from its
    # escape, nor a surrogate pair.
    param([string] $Text)

    $septets = ConvertTo-Gsm7Septet -Text $Text
    $alphabet = if ($null -ne $septets) { 'Gsm7' } else { 'Ucs2' }
    $groups = [System.Collections.Generic.List[object]]::new()
    $units = 0
    $characters = $Text.ToCharArray()
    for ($i = 0; $i -lt $characters.Count; $i++) {
        $group = if ($alphabet -eq 'Gsm7') {
            , [object[]]$script:Gsm7Septets[$characters[$i]]
        }
        elseif ([char]::IsHighSurrogate($characters[$i]) -and $i + 1 -lt $characters.Count -and [char]::IsLowSurrogate($characters[$i + 1])) {
            $i++
            , [object[]]@($characters[$i - 1], $characters[$i])
        }
        else {
            , [object[]]@($characters[$i])
        }
        $groups.Add($group)
        $units += $group.Count
    }
    $limits = $script:SmsLimits[$alphabet]
    $size = if ($units -le $limits.Single) { $limits.Single } else { $limits.Part }
    $parts = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[object]]::new()
    foreach ($group in $groups) {
        if ($current.Count + $group.Count -gt $size) {
            $parts.Add($current.ToArray())
            $current = [System.Collections.Generic.List[object]]::new()
        }
        $current.AddRange($group)
    }
    if ($current.Count -gt 0 -or $parts.Count -eq 0) {
        $parts.Add($current.ToArray())
    }
    [pscustomobject]@{ Alphabet = $alphabet; Units = $units; PerPart = $size; Parts = $parts.ToArray() }
}

function Measure-SmsText {
    <#
    .SYNOPSIS
        Says how a text would be sent: its alphabet, its length and how many messages it takes.
    .DESCRIPTION
        A pure function. GSM 7-bit when every character is in the GSM 7 bit default alphabet or
        its extension table (an extension character counts two), else UCS2, counted in UTF-16 code
        units. Returns Alphabet ('Gsm7' or 'Ucs2'), Length (septets or code units), PerPart (what
        one message holds: 160 or 70 alone, 153 or 67 as a part of a long one), Parts, and
        TooLong: more than 255 parts, which can't be sent (docs/AT-COMMANDS.md section 9, SMS
        PDUs).
    .EXAMPLE
        Measure-SmsText -Text 'Hello'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $split = Split-SmsText -Text $Text
    [pscustomobject]@{
        Alphabet = $split.Alphabet
        Length   = $split.Units
        PerPart  = $split.PerPart
        Parts    = $split.Parts.Count
        TooLong  = $split.Parts.Count -gt $script:SmsMaxParts
    }
}

function ConvertTo-SmsPdu {
    <#
    .SYNOPSIS
        Encodes a text message to a number as the PDUs AT+CMGS takes: one, or the parts of a long
        message.
    .DESCRIPTION
        A pure function, written from 3GPP TS 23.040 and 23.038 (docs/AT-COMMANDS.md section 9,
        SMS PDUs). Each PDU is an SMS-SUBMIT preceded by an empty service-centre address, so the
        modem uses the SIM's (+CSCA); no validity period (the centre's own), no status report,
        message reference 0. GSM 7-bit when the alphabet holds every character, else UCS2 (UTF-16,
        surrogate pairs kept whole). A text longer than one message is split into parts, each with
        a header naming -Reference (0-255; the same for every part), the count and its number; an
        escaped character or a surrogate pair is never split.

        -Number: digits, '+' first for an international number; 1 to 20 digits. Returns one object
        per part: Pdu (hexadecimal), Length (the TPDU's octets, AT+CMGS's argument), Part, Count.
        Refuses a number of another shape, and a text of more than 255 parts.
    .EXAMPLE
        ConvertTo-SmsPdu -Number '+15550100' -Text 'Hello' -Reference 1
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Number,

        [Parameter(Mandatory)]
        [string] $Text,

        [ValidateRange(0, 255)]
        [int] $Reference = 0
    )

    if ($Number -notmatch '^\+?[0-9]{1,20}$') {
        throw [System.ArgumentException]::new('A number is digits, with a + first for an international one: 1 to 20 digits.', 'Number')
    }
    $split = Split-SmsText -Text $Text
    $count = $split.Parts.Count
    if ($count -gt $script:SmsMaxParts) {
        throw [System.ArgumentException]::new("The text takes $count messages; at most $script:SmsMaxParts can be joined.", 'Text')
    }
    $address = ConvertTo-SmsAddress -Number $Number
    $long = $count -gt 1
    for ($part = 1; $part -le $count; $part++) {
        $units = $split.Parts[$part - 1]
        # The long message's header: its length, element 0x00 (one-octet reference), 3 octets.
        $header = [byte[]]@(if ($long) { 0x05, 0x00, 0x03, $Reference, $count, $part })
        if ($split.Alphabet -eq 'Gsm7') {
            $headerSeptets = [int][Math]::Ceiling($header.Count * 8 / 7)
            $fill = 7 * $headerSeptets - 8 * $header.Count
            $body = Compress-SmsSeptet -Septets ([byte[]]$units) -FillBits $fill
            $length = $headerSeptets + $units.Count
            $dcs = 0x00
        }
        else {
            $body = [System.Text.Encoding]::BigEndianUnicode.GetBytes([char[]]$units)
            $length = $header.Count + $body.Count
            $dcs = 0x08
        }
        $tpdu = [System.Collections.Generic.List[byte]]::new()
        # SMS-SUBMIT, no validity period; the header indicator for a part of a long message.
        $tpdu.Add($(if ($long) { 0x41 } else { 0x01 }))
        $tpdu.Add(0x00)
        $tpdu.AddRange([byte[]]$address)
        $tpdu.Add(0x00)
        $tpdu.Add($dcs)
        $tpdu.Add($length)
        $tpdu.AddRange($header)
        $tpdu.AddRange([byte[]]$body)
        [pscustomobject]@{
            Pdu    = '00' + [Convert]::ToHexString($tpdu.ToArray())
            Length = $tpdu.Count
            Part   = $part
            Count  = $count
        }
    }
}

function Join-SmsPart {
    <#
    .SYNOPSIS
        Groups the messages read from the modem's storage into what the user reads: a long
        message's parts joined, in order.
    .DESCRIPTION
        A pure function. -Entry: the stored messages, each with Index, Status ('Unread', 'Read',
        'Unsent', 'Sent'), Sms (ConvertFrom-SmsPdu's) and, optionally, Pdu. The parts of one long message share its
        type, address, reference and count (23.040 clause 9.2.3.24.1; the service centre is not
        compared); a part stored twice counts once, both indexes kept.

        Returns one object per message, newest first: Indexes (every place it takes in the
        storage, in part order - what deleting it deletes), Fingerprints (its parts', from their
        PDUs: Get-SmsFingerprint), Status ('Unread' when a part is),
        Type, Address, AddressType, Time (the first part's, else the earliest), Text (the parts
        received, in order, with an ellipsis where parts are missing; $null when no part has text),
        Content, Class, Silent, Waiting, NationalLanguage, Problem, Count (the parts it has in
        all; 1 for a single message), Missing (the numbers of the parts not received) and
        Complete.
    .EXAMPLE
        Join-SmsPart -Entry $entries
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Entry
    )

    $groups = [ordered]@{}
    foreach ($item in $Entry | Sort-Object -Property Index) {
        $sms = $item.Sms
        $key = if ($sms.Concat) {
            "$($sms.Type)|$($sms.Address)|$($sms.Concat.Wide)|$($sms.Concat.Reference)|$($sms.Concat.Count)"
        }
        else {
            "single|$($item.Index)"
        }
        if (-not $groups.Contains($key)) {
            $groups[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$key].Add($item)
    }
    $messages = foreach ($items in $groups.Values) {
        $first = $items[0].Sms
        $count = if ($first.Concat) { $first.Concat.Count } else { 1 }
        # Part numbers as string keys: an ordered dictionary reads an integer key as a position.
        $byPart = [ordered]@{}
        foreach ($item in $items) {
            $number = if ($item.Sms.Concat) { "$($item.Sms.Concat.Part)" } else { '1' }
            if (-not $byPart.Contains($number)) {
                $byPart[$number] = $item
            }
        }
        $missing = [int[]]@(1..$count | Where-Object { -not $byPart.Contains("$_") })
        $pieces = foreach ($number in 1..$count) {
            if ($byPart.Contains("$number")) { $byPart["$number"].Sms.Text } else { $null }
        }
        # A run of missing parts becomes one ellipsis, a blank on each side that has text.
        $pieces = @($pieces)
        $text = [System.Text.StringBuilder]::new()
        for ($i = 0; $i -lt $pieces.Count; $i++) {
            if ($null -ne $pieces[$i]) {
                [void]$text.Append($pieces[$i])
            }
            elseif ($i -eq 0 -or $null -ne $pieces[$i - 1]) {
                $after = $i + 1 -lt $pieces.Count -and @($pieces[($i + 1)..($pieces.Count - 1)] | Where-Object { $null -ne $_ }).Count -gt 0
                [void]$text.Append($(if ($i -gt 0) { ' ' }) + [char]0x2026 + $(if ($after) { ' ' }))
            }
        }
        $ordered = @($items | Sort-Object -Property { if ($_.Sms.Concat) { $_.Sms.Concat.Part } else { 1 } }, Index)
        $lead = if ($byPart.Contains('1')) { $byPart['1'].Sms } else { $null }
        $times = @($items | ForEach-Object { $_.Sms.Time } | Where-Object { $null -ne $_ } | Sort-Object)
        $anyText = @($items | Where-Object { $null -ne $_.Sms.Text }).Count -gt 0
        [pscustomobject]@{
            Indexes          = [int[]]@($ordered | ForEach-Object Index)
            Fingerprints     = [string[]]@($ordered | Where-Object { $_.PSObject.Properties['Pdu'] -and $_.Pdu } | ForEach-Object { Get-SmsFingerprint -Pdu $_.Pdu })
            Status           = if (@($items | Where-Object Status -EQ 'Unread').Count) { 'Unread' } else { $items[0].Status }
            Type             = $first.Type
            Address          = $first.Address
            AddressType      = $first.AddressType
            Time             = if ($lead -and $lead.Time) { $lead.Time } elseif ($times.Count) { $times[0] } else { $null }
            Text             = if ($anyText) { $text.ToString() } else { $null }
            Content          = $first.Content
            Class            = $first.Class
            Silent           = [bool]$first.Silent
            Waiting          = $first.Waiting
            NationalLanguage = @($items | Where-Object { $_.Sms.NationalLanguage }).Count -gt 0
            Problem          = $first.Problem
            Count            = $count
            Missing          = $missing
            Complete         = $missing.Count -eq 0
        }
    }
    $newest = @{ Expression = { if ($_.Time) { $_.Time.UtcDateTime } else { [datetime]::MinValue } }; Descending = $true }
    $latest = @{ Expression = { ($_.Indexes | Measure-Object -Maximum).Maximum }; Descending = $true }
    @($messages) | Sort-Object -Property $newest, $latest
}

function ConvertFrom-AtMessageList {
    <#
    .SYNOPSIS
        Parses the stored messages that AT+CMGL (or AT+CMGR=<index>, with -Index) lists in PDU mode.
    .DESCRIPTION
        A pure parser (27.005 clauses 4.1, 4.2; docs/AT-COMMANDS.md section 9): each '+CMGL:
        <index>,<stat>,[<alpha>],<length>' line followed by its PDU on the next line, or AT+CMGR's
        '+CMGR: <stat>,[<alpha>],<length>' and its PDU for the index given. Other lines are
        ignored; a header without its PDU is left out. Returns Index, Status ('Unread', 'Read',
        'Unsent', 'Sent', or $null for a value not documented), Length and Pdu.
    .EXAMPLE
        ConvertFrom-AtMessageList -Lines (Invoke-AtCommand -Channel $channel -Command 'AT+CMGL=4').Lines
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Lines = @(),

        # AT+CMGR's answer: the index read.
        [Nullable[int]] $Index
    )

    $states = @('Unread', 'Read', 'Unsent', 'Sent')
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $prefix = if ($null -ne $Index) { '+CMGR' } else { '+CMGL' }
        if ($Lines[$i] -notmatch "^\s*\$prefix\s*:\s*(.*)$") {
            continue
        }
        $arguments = @(Split-AtArgument -Text $Matches[1])
        $next = if ($i + 1 -lt $Lines.Count) { $Lines[$i + 1].Trim() } else { '' }
        if ($next -notmatch '^(?:[0-9A-Fa-f]{2})+$') {
            continue
        }
        $i++
        $values = @($arguments | ForEach-Object Value)
        if ($null -eq $Index) {
            # The index, then the status at least: a header without them is left out.
            $entryIndex = if ($values.Count -ge 2) { ConvertTo-AtInteger -Text $values[0] } else { $null }
            if ($null -eq $entryIndex) {
                continue
            }
            $values = @($values | Select-Object -Skip 1)
        }
        else {
            $entryIndex = $Index
        }
        if ($values.Count -eq 0) {
            continue
        }
        $state = ConvertTo-AtInteger -Text $values[0]
        [pscustomobject]@{
            Index  = $entryIndex
            Status = if ($null -ne $state -and $state -ge 0 -and $state -lt $states.Count) { $states[$state] } else { $null }
            Length = ConvertTo-AtInteger -Text $values[-1]
            Pdu    = $next.ToUpperInvariant()
        }
    }
}

function ConvertFrom-AtMessageStorage {
    <#
    .SYNOPSIS
        Parses AT+CPMS?: the storages for reading, writing and receiving messages, and how full
        each is.
    .DESCRIPTION
        A pure parser (27.005 clause 3.2.2). Returns Read, Write and Receive, each with Memory,
        Used and Total; $null when the answer doesn't carry them.
    .EXAMPLE
        ConvertFrom-AtMessageStorage -Lines (Invoke-AtCommand -Channel $channel -Command 'AT+CPMS?').Lines
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Lines = @()
    )

    $text = @(Get-AtPrefixedLine -Lines $Lines -Prefix '+CPMS') | Select-Object -First 1
    if ($null -eq $text) {
        return $null
    }
    # The device puts a blank after each comma, before the quotes too.
    $values = @(Split-AtArgument -Text $text | ForEach-Object { $_.Value.Trim() })
    if ($values.Count -lt 9) {
        return $null
    }
    $storage = {
        param([int] $at)
        $used = ConvertTo-AtInteger -Text $values[$at + 1]
        $total = ConvertTo-AtInteger -Text $values[$at + 2]
        if ($values[$at] -and $null -ne $used -and $null -ne $total) {
            [pscustomobject]@{ Memory = $values[$at]; Used = $used; Total = $total }
        }
    }
    $read = & $storage 0
    $write = & $storage 3
    $receive = & $storage 6
    if (-not ($read -and $write -and $receive)) {
        return $null
    }
    [pscustomobject]@{ Read = $read; Write = $write; Receive = $receive }
}

function ConvertFrom-AtNewMessage {
    <#
    .SYNOPSIS
        Parses a new-message notice, '+CMTI: <mem>,<index>'.
    .DESCRIPTION
        A pure parser (27.005 clause 3.4.1). Returns Memory and Index, or $null for another line.
    .EXAMPLE
        ConvertFrom-AtNewMessage -Line '+CMTI: "ME",3'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Line
    )

    $text = @(Get-AtPrefixedLine -Lines @($Line) -Prefix '+CMTI') | Select-Object -First 1
    if ($null -eq $text) {
        return $null
    }
    $values = @(Split-AtArgument -Text $text | ForEach-Object Value)
    $index = if ($values.Count -ge 2) { ConvertTo-AtInteger -Text $values[1] } else { $null }
    if (-not $values[0] -or $null -eq $index) {
        return $null
    }
    [pscustomobject]@{ Memory = $values[0]; Index = $index }
}

function Get-SmsFingerprint {
    <#
    .SYNOPSIS
        Returns a stored message part's fingerprint: the SHA-256 of its PDU.
    .DESCRIPTION
        A pure function. The PDU holds the sender, the time stamp, the long message's reference
        and the text, so the fingerprint names the part wherever the storage keeps it, and tells
        nothing of it (ARCHITECTURE -> SMS: what is new is remembered by the message).
    .EXAMPLE
        Get-SmsFingerprint -Pdu $entry.Pdu
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Pdu
    )

    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Pdu.Trim().ToUpperInvariant())
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))
}

function Update-SmsUnread {
    <#
    .SYNOPSIS
        Decides which stored message parts are new, after a reading of the whole storage.
    .DESCRIPTION
        A pure function. -Unread: the fingerprints new before; -Entry: what AT+CMGL=4 listed
        (Pdu, Status); -Opened: the fingerprints of the parts the user opened since. A part the
        modem reports unread is new - the listing has just marked it read on the modem -; a part
        new before stays new while it is stored; a part opened is new no more. Returns the
        fingerprints, sorted: never more than the storage holds.
    .EXAMPLE
        $unread = Update-SmsUnread -Unread $unread -Entry $entries
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure: returns the new list and changes nothing.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Unread = @(),

        [AllowEmptyCollection()]
        [object[]] $Entry = @(),

        [AllowEmptyCollection()]
        [string[]] $Opened = @()
    )

    $stored = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $new = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Entry) {
        $fingerprint = Get-SmsFingerprint -Pdu $item.Pdu
        [void]$stored.Add($fingerprint)
        if ($item.Status -eq 'Unread') {
            [void]$new.Add($fingerprint)
        }
    }
    foreach ($fingerprint in $Unread) {
        if ($fingerprint -and $stored.Contains($fingerprint)) {
            [void]$new.Add($fingerprint)
        }
    }
    foreach ($fingerprint in $Opened) {
        if ($fingerprint) {
            [void]$new.Remove($fingerprint)
        }
    }
    [string[]]@($new)
}

function Import-SmsUnread {
    <#
    .SYNOPSIS
        Reads the fingerprints of the message parts still new.
    .DESCRIPTION
        The file holds them encrypted with DPAPI for the current user (Export-SmsUnread). No
        file gives none; a file that can't be read or decrypted gives none too, with a warning:
        the messages then show as read.
    .EXAMPLE
        $unread = Import-SmsUnread -Path $path
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        $secret = ConvertFrom-ProtectedText -Text (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
        if (-not $secret) {
            throw [System.Security.Cryptography.CryptographicException]::new('Not decrypted.')
        }
        $json = [System.Net.NetworkCredential]::new('', $secret).Password
        $fingerprints = @($json | ConvertFrom-Json -ErrorAction Stop)
        if (@($fingerprints | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[0-9A-F]{64}$' }).Count) {
            throw [System.FormatException]::new('Not a list of fingerprints.')
        }
        [string[]]$fingerprints
    }
    catch {
        Write-Warning "The list of new messages can't be read ($($_.Exception.GetType().Name)); they show as read."
    }
}

function Export-SmsUnread {
    <#
    .SYNOPSIS
        Writes the fingerprints of the message parts still new, encrypted for the current user.
    .DESCRIPTION
        One file, rewritten whole (a temporary file, then a move), encrypted with DPAPI: no text,
        no number - fingerprints only (Get-SmsFingerprint).
    .EXAMPLE
        Export-SmsUnread -Fingerprint $unread -Path $path
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Fingerprint,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $json = ConvertTo-Json -InputObject ([string[]]@($Fingerprint)) -Compress
    if ($PSCmdlet.ShouldProcess($Path, 'Write the list of new messages')) {
        Write-AppFile -Path $Path -Content (ConvertTo-ProtectedText -Text $json)
    }
}

# How many message parts the app remembers the SIM of: the oldest are forgotten first. A storage
# holds a few hundred at most.
$script:SmsOwnersKept = 1000

function Update-SmsOwner {
    <#
    .SYNOPSIS
        Remembers which SIM each message part came in on, after a reading of the storage.
    .DESCRIPTION
        A pure function (decided 2026-10-04). On the eUICC's slot the modem keeps part of the
        messages for the slot, whichever profile is enabled (AT-COMMANDS section 9): the app tells
        them apart by the SIM they came in on. -Owner: the parts remembered - Message (the part's
        fingerprint, Get-SmsFingerprint's), Sim (the SIM's, Get-SimSettingFingerprint's), Kind
        ('Usim' or 'Esim') and Name (the eSIM profile's, or '') -; -Entry: what AT+CMGL=4 listed
        (Pdu, Status); -Sim, -Kind and -Name: the SIM in use.
        A part the modem reports unread came in since the storage was last read, on the SIM in
        use - the only one registered. A part already read when first seen keeps no SIM: where it
        came in is not known. Without -Sim nothing is added. A part of the SIM in use takes its
        name as it is now. The newest 1000 are kept. Returns the entries.
    .EXAMPLE
        $owners = Update-SmsOwner -Owner $owners -Entry $entries -Sim $fingerprint -Kind Esim -Name 'Travel'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure: returns the new list and changes nothing.')]
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Owner = @(),

        [AllowEmptyCollection()]
        [object[]] $Entry = @(),

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Sim,

        [ValidateSet('Usim', 'Esim', '')]
        [string] $Kind = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string] $Name = ''
    )

    $kept = [System.Collections.Generic.List[object]]::new()
    $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Owner | Where-Object { $_ })) {
        $named = if ($Sim -and $Name -and $item.Sim -eq $Sim) { $Name } else { [string]$item.Name }
        $kept.Add([pscustomobject]@{ Message = $item.Message; Sim = $item.Sim; Kind = $item.Kind; Name = $named })
        [void]$known.Add($item.Message)
    }
    if ($Sim) {
        foreach ($item in $Entry) {
            $fingerprint = Get-SmsFingerprint -Pdu $item.Pdu
            if ($item.Status -eq 'Unread' -and $known.Add($fingerprint)) {
                $kept.Add([pscustomobject]@{ Message = $fingerprint; Sim = $Sim; Kind = $Kind; Name = [string]$Name })
            }
        }
    }
    [object[]]@($kept | Select-Object -Last $script:SmsOwnersKept)
}

function Import-SmsOwner {
    <#
    .SYNOPSIS
        Reads which SIM the message parts came in on (Update-SmsOwner's entries).
    .DESCRIPTION
        The file holds them encrypted with DPAPI for the current user (Export-SmsOwner). No file
        gives none; a file that can't be read or decrypted gives none too, with a warning: every
        message then shows, its SIM not known.
    .EXAMPLE
        $owners = Import-SmsOwner -Path $path
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        $secret = ConvertFrom-ProtectedText -Text (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
        if (-not $secret) {
            throw [System.Security.Cryptography.CryptographicException]::new('Not decrypted.')
        }
        $json = [System.Net.NetworkCredential]::new('', $secret).Password
        $entries = @($json | ConvertFrom-Json -ErrorAction Stop)
        $bad = @($entries | Where-Object {
                -not $_ -or [string]$_.Message -notmatch '^[0-9A-F]{64}$' -or [string]$_.Sim -notmatch '^[0-9A-F]{64}$' -or [string]$_.Kind -notin 'Usim', 'Esim', ''
            })
        if ($bad.Count) {
            throw [System.FormatException]::new('Not a list of message parts and their SIMs.')
        }
        [object[]]@($entries | ForEach-Object { [pscustomobject]@{ Message = [string]$_.Message; Sim = [string]$_.Sim; Kind = [string]$_.Kind; Name = [string]$_.Name } })
    }
    catch {
        Write-Warning "The SIMs the messages came in on can't be read ($($_.Exception.GetType().Name)); every message shows."
    }
}

function Export-SmsOwner {
    <#
    .SYNOPSIS
        Writes which SIM the message parts came in on, encrypted for the current user.
    .DESCRIPTION
        One file, rewritten whole, encrypted with DPAPI: fingerprints of parts and SIMs, the kind
        of SIM and an eSIM profile's name - no text, no number, no ICCID.
    .EXAMPLE
        Export-SmsOwner -Owner $owners -Path $path
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Owner,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $json = ConvertTo-Json -InputObject ([object[]]@($Owner | Select-Object -Property Message, Sim, Kind, Name)) -Compress -Depth 3
    if ($PSCmdlet.ShouldProcess($Path, 'Write the SIMs the messages came in on')) {
        Write-AppFile -Path $Path -Content (ConvertTo-ProtectedText -Text $json)
    }
}
