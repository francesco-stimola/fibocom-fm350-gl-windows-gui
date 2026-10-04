# The SMS codec (src/FibocomFm350/Sms.ps1), written from 3GPP TS 23.040, 23.038, 24.011 and
# 27.005 (docs/AT-COMMANDS.md section 9). PDUs are built by hand from those layouts; packed
# GSM 7-bit text comes from a reference that draws the packing as a string of bits, apart from the
# module's arithmetic ('hello' gives E8329BFD06, the usual example). Numbers are the fixture fakes.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"
    $script:module = Get-Module FibocomFm350

    # 23.038 clause 6.1.2.1.1 as a string of bits: each septet lowest bit first, after -Fill zero
    # bits, cut into octets read lowest bit first.
    function ConvertTo-TestPacked {
        param([int[]] $Septets, [int] $Fill = 0)

        $bits = ('0' * $Fill) + (-join ($Septets | ForEach-Object { -join [Convert]::ToString($_, 2).PadLeft(7, '0').ToCharArray()[6..0] }))
        $bits = $bits.PadRight([int][Math]::Ceiling($bits.Length / 8) * 8, '0')
        -join (0..($bits.Length / 8 - 1) | ForEach-Object { '{0:X2}' -f [Convert]::ToInt32((-join $bits.Substring($_ * 8, 8).ToCharArray()[7..0]), 2) })
    }

    # An SMS-DELIVER as +CMGL lists it: the service centre, then the TPDU's fields.
    function Get-TestDeliverPdu {
        param(
            [string] $First = '04', [string] $Originator = '0B910100000000F0', [string] $Protocol = '00',
            [string] $Dcs = '00', [string] $Time = '62014021436580', [string] $UserData = '05E8329BFD06'
        )

        '07910100000000F0' + $First + $Originator + $Protocol + $Dcs + $Time + $UserData
    }

    # A stored message as Join-SmsPart takes it, decoded as ConvertFrom-SmsPdu returns it.
    function Get-TestEntry {
        param(
            [int] $Index, [string] $Status = 'Read', [string] $Address = '+10000000000', [AllowNull()] [string] $Text = 'text',
            [Nullable[DateTimeOffset]] $Time = [DateTimeOffset]::new(2026, 10, 4, 12, 0, 0, [TimeSpan]::Zero),
            [Nullable[int]] $Reference, [int] $Count = 2, [int] $Part = 1, [switch] $Wide, [string] $Problem
        )

        $concat = if ($null -ne $Reference) { [pscustomobject]@{ Reference = $Reference; Wide = [bool]$Wide; Count = $Count; Part = $Part } } else { $null }
        [pscustomobject]@{
            Index  = $Index
            Status = $Status
            Sms    = [pscustomobject]@{
                Type = if ($Problem) { $null } else { 'Deliver' }; ServiceCentre = $null; Address = $Address; AddressType = 'International'
                Problem = if ($Problem) { $Problem } else { $null }; Content = 'Text'; Text = $Text; Alphabet = 'Gsm7'; Class = $null
                Waiting = $null; Silent = $false; Concat = $concat; NationalLanguage = $false; Time = $Time
                Reference = $null; Discharged = $null; Status = $null; Outcome = $null
            }
        }
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'The reference packing the tests use' {
    It 'gives the usual examples' {
        ConvertTo-TestPacked -Septets ([int[]][char[]]'hello') | Should -Be 'E8329BFD06'
        ConvertTo-TestPacked -Septets ([int[]][char[]]'hellohello') | Should -Be 'E8329BFD4697D9EC37'
    }
}

Describe 'ConvertFrom-SmsPdu: a message received' {
    It 'reads <Name>' -ForEach @(
        @{ Name = 'GSM 7-bit text from an international number'; Originator = '0B910100000000F0'; Dcs = '00'; UserData = '05E8329BFD06'; Address = '+10000000000'; AddressType = 'International'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'a national number'; Originator = '0BA10100000000F0'; Dcs = '00'; UserData = '05E8329BFD06'; Address = '10000000000'; AddressType = 'National'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'a number of unknown type, even digits'; Originator = '0A810100000000'; Dcs = '00'; UserData = '05E8329BFD06'; Address = '1000000000'; AddressType = 'Unknown'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'a sender''s name'; Originator = '0ED04F78591EA6BFE5'; Dcs = '00'; UserData = '05E8329BFD06'; Address = 'Operator'; AddressType = 'Alphanumeric'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'a name whose last semi-octets hold part of a character'; Originator = '06D049B719'; Dcs = '00'; UserData = '05E8329BFD06'; Address = 'Inf'; AddressType = 'Alphanumeric'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'a short name, an odd count of semi-octets'; Originator = '07D049B7F90D'; Dcs = '00'; UserData = '05E8329BFD06'; Address = 'Info'; AddressType = 'Alphanumeric'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'an address with * and #'; Originator = '04811AB2'; Dcs = '00'; UserData = '05E8329BFD06'; Address = '*12#'; AddressType = 'Unknown'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'a fill semi-octet before the last, skipped'; Originator = '0481F132'; Dcs = '00'; UserData = '05E8329BFD06'; Address = '123'; AddressType = 'Unknown'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'a reserved type of number, read as unknown'; Originator = '0BF10100000000F0'; Dcs = '00'; UserData = '05E8329BFD06'; Address = '10000000000'; AddressType = 'Unknown'; Text = 'hello'; Alphabet = 'Gsm7' }
        @{ Name = 'UCS2 text'; Originator = '0B910100000000F0'; Dcs = '08'; UserData = '08004300690061006F'; Address = '+10000000000'; AddressType = 'International'; Text = 'Ciao'; Alphabet = 'Ucs2' }
        @{ Name = 'UCS2 beyond the basic plane, a surrogate pair'; Originator = '0B910100000000F0'; Dcs = '08'; UserData = '04D83DDE00'; Address = '+10000000000'; AddressType = 'International'; Text = [char]::ConvertFromUtf32(0x1F600); Alphabet = 'Ucs2' }
        @{ Name = 'UCS2 with an odd octet left over, dropped'; Originator = '0B910100000000F0'; Dcs = '08'; UserData = '0300430069'; Address = '+10000000000'; AddressType = 'International'; Text = 'C'; Alphabet = 'Ucs2' }
        @{ Name = 'extension characters'; Originator = '0B910100000000F0'; Dcs = '00'; UserData = '05E14D798302'; Address = '+10000000000'; AddressType = 'International'; Text = 'a€{'; Alphabet = 'Gsm7' }
        @{ Name = 'an escaped septet the extension table lacks, as the default character'; Originator = '0B910100000000F0'; Dcs = '00'; UserData = '029B20'; Address = '+10000000000'; AddressType = 'International'; Text = 'A'; Alphabet = 'Gsm7' }
        @{ Name = 'two escapes, as a space'; Originator = '0B910100000000F0'; Dcs = '00'; UserData = '039B4D18'; Address = '+10000000000'; AddressType = 'International'; Text = ' a'; Alphabet = 'Gsm7' }
        @{ Name = 'a lone escape at the end, as nothing'; Originator = '0B910100000000F0'; Dcs = '00'; UserData = '02E10D'; Address = '+10000000000'; AddressType = 'International'; Text = 'a'; Alphabet = 'Gsm7' }
        @{ Name = 'the default alphabet''s own characters'; Originator = '0B910100000000F0'; Dcs = '00'; UserData = '07808000F2573400'; Address = '+10000000000'; AddressType = 'International'; Text = '@£$Δà' + "`n`r"; Alphabet = 'Gsm7' }
        @{ Name = 'no user data'; Originator = '0B910100000000F0'; Dcs = '00'; UserData = '00'; Address = '+10000000000'; AddressType = 'International'; Text = ''; Alphabet = 'Gsm7' }
    ) {
        $sms = ConvertFrom-SmsPdu -Pdu (Get-TestDeliverPdu -Originator $Originator -Dcs $Dcs -UserData $UserData)

        $sms.Problem | Should -BeNullOrEmpty
        $sms.Type | Should -Be 'Deliver'
        $sms.ServiceCentre | Should -Be '+10000000000'
        $sms.Address | Should -Be $Address
        $sms.AddressType | Should -Be $AddressType
        $sms.Text | Should -BeExactly $Text
        $sms.Alphabet | Should -Be $Alphabet
        $sms.Content | Should -Be 'Text'
        $sms.Concat | Should -BeNullOrEmpty
    }

    It 'reads the time stamp <Name>' -ForEach @(
        @{ Name = 'with its time zone ahead of GMT'; Time = '62014021436580'; Expected = '2026-10-04T12:34:56+02:00' }
        @{ Name = 'behind GMT, the sign in bit 3'; Time = '6201402143650A'; Expected = '2026-10-04T12:34:56-05:00' }
        @{ Name = 'in quarters of an hour'; Time = '62014021436532'; Expected = '2026-10-04T12:34:56+05:45' }
        @{ Name = 'at GMT'; Time = '62014021436500'; Expected = '2026-10-04T12:34:56+00:00' }
        @{ Name = 'with a units digit that is not one, read as 0'; Time = '6201402143F580'; Expected = '2026-10-04T12:34:50+02:00' }
        @{ Name = 'with a tens digit that is not one, read as 0'; Time = '62014021435F80'; Expected = '2026-10-04T12:34:05+02:00' }
        @{ Name = 'of a date that doesn''t exist, as none'; Time = '62310021436580'; Expected = $null }
    ) {
        $sms = ConvertFrom-SmsPdu -Pdu (Get-TestDeliverPdu -Time $Time)

        if ($Expected) {
            $sms.Time.ToString('yyyy-MM-ddTHH:mm:sszzz', [cultureinfo]::InvariantCulture) | Should -Be $Expected
        }
        else {
            $sms.Time | Should -BeNullOrEmpty
            $sms.Problem | Should -BeNullOrEmpty
            $sms.Text | Should -Be 'hello'
        }
    }

    It 'reads the part of a long message, its text after the header''s fill bits' {
        $userData = '0F' + '0500032A0201' + (ConvertTo-TestPacked -Septets ([int[]][char[]]'Part one') -Fill 1)
        $sms = ConvertFrom-SmsPdu -Pdu (Get-TestDeliverPdu -First '44' -Originator '0ED04F78591EA6BFE5' -UserData $userData)

        $sms.Text | Should -Be 'Part one'
        $sms.Address | Should -Be 'Operator'
        $sms.Concat.Reference | Should -Be 42
        $sms.Concat.Wide | Should -BeFalse
        $sms.Concat.Count | Should -Be 2
        $sms.Concat.Part | Should -Be 1
    }

    It 'reads the part of a long message in UCS2, with a two-octet reference' {
        $sms = ConvertFrom-SmsPdu -Pdu (Get-TestDeliverPdu -First '44' -Dcs '08' -UserData ('0F' + '06080412340302' + '004300690061006F'))

        $sms.Text | Should -Be 'Ciao'
        $sms.Concat.Reference | Should -Be 0x1234
        $sms.Concat.Wide | Should -BeTrue
        $sms.Concat.Count | Should -Be 3
        $sms.Concat.Part | Should -Be 2
    }

    It 'notes a national language table, and reads the text with the default ones' {
        # A 4-octet header takes 5 septets: 3 fill bits.
        $userData = '0A' + '03240101' + (ConvertTo-TestPacked -Septets ([int[]][char[]]'hello') -Fill 3)
        $sms = ConvertFrom-SmsPdu -Pdu (Get-TestDeliverPdu -First '44' -UserData $userData)

        $sms.NationalLanguage | Should -BeTrue
        $sms.Text | Should -Be 'hello'
        $sms.Concat | Should -BeNullOrEmpty
    }

    It 'gives no text for <Name>' -ForEach @(
        @{ Name = '8-bit data'; Dcs = '04'; UserData = '03010203'; Content = 'Binary'; Alphabet = 'Data8' }
        @{ Name = 'compressed text'; Dcs = '20'; UserData = '03010203'; Content = 'Compressed'; Alphabet = 'Gsm7' }
        @{ Name = '8-bit data with a class'; Dcs = 'F6'; UserData = '03010203'; Content = 'Binary'; Alphabet = 'Data8' }
    ) {
        $sms = ConvertFrom-SmsPdu -Pdu (Get-TestDeliverPdu -Dcs $Dcs -UserData $UserData)

        $sms.Problem | Should -BeNullOrEmpty
        $sms.Content | Should -Be $Content
        $sms.Alphabet | Should -Be $Alphabet
        $sms.Text | Should -BeNullOrEmpty
    }

    It 'says a message is <Name>' -ForEach @(
        @{ Name = 'of class 0, shown at once'; Protocol = '00'; Dcs = '10'; Class = 0; Silent = $false; Waiting = $null }
        @{ Name = 'silent: a short message type 0'; Protocol = '40'; Dcs = '00'; Class = $null; Silent = $true; Waiting = $null }
        @{ Name = 'a voicemail waiting'; Protocol = '00'; Dcs = 'C8'; Class = $null; Silent = $false; Waiting = 'Voicemail' }
    ) {
        $sms = ConvertFrom-SmsPdu -Pdu (Get-TestDeliverPdu -Protocol $Protocol -Dcs $Dcs)

        $sms.Class | Should -Be $Class
        $sms.Silent | Should -Be $Silent
        if ($Waiting) { $sms.Waiting.Kind | Should -Be $Waiting } else { $sms.Waiting | Should -BeNullOrEmpty }
        $sms.Text | Should -Be 'hello'
    }

    It 'reads a reserved message type as a message received' {
        (ConvertFrom-SmsPdu -Pdu (Get-TestDeliverPdu -First '07')).Type | Should -Be 'Deliver'
    }

    It 'reads a TPDU alone' {
        $sms = ConvertFrom-SmsPdu -Pdu '040B910100000000F000006201402143658005E8329BFD06' -NoServiceCentre

        $sms.ServiceCentre | Should -BeNullOrEmpty
        $sms.Text | Should -Be 'hello'
    }

    It 'reads an empty service-centre address as none' {
        (ConvertFrom-SmsPdu -Pdu '00040B910100000000F000006201402143658005E8329BFD06').ServiceCentre | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-SmsPdu: a message stored to send, and a status report' {
    It 'reads a message to send with <Name>' -ForEach @(
        @{ Name = 'no validity period'; First = '01'; Validity = '' }
        @{ Name = 'a relative validity period'; First = '11'; Validity = 'A7' }
        @{ Name = 'an absolute validity period'; First = '19'; Validity = '62014021436580' }
        @{ Name = 'an enhanced validity period'; First = '09'; Validity = '01000000000000' }
    ) {
        $sms = ConvertFrom-SmsPdu -Pdu ('00' + $First + '05' + '0B910100000000F0' + '0000' + $Validity + '05E8329BFD06')

        $sms.Problem | Should -BeNullOrEmpty
        $sms.Type | Should -Be 'Submit'
        $sms.Reference | Should -Be 5
        $sms.Address | Should -Be '+10000000000'
        $sms.Text | Should -Be 'hello'
        $sms.Time | Should -BeNullOrEmpty
    }

    It 'reads a status report' {
        $sms = ConvertFrom-SmsPdu -Pdu ('00' + '06' + '2A' + '0B910100000000F0' + '62014021436580' + '62014021536580' + '00')

        $sms.Type | Should -Be 'StatusReport'
        $sms.Reference | Should -Be 42
        $sms.Address | Should -Be '+10000000000'
        $sms.Time.ToString('HH:mm:ss', [cultureinfo]::InvariantCulture) | Should -Be '12:34:56'
        $sms.Discharged.ToString('HH:mm:ss', [cultureinfo]::InvariantCulture) | Should -Be '12:35:56'
        $sms.Status | Should -Be 0
        $sms.Outcome | Should -Be 'Delivered'
    }

    It 'reads a status <Status> as <Outcome>' -ForEach @(
        @{ Status = 0x00; Outcome = 'Delivered' }
        @{ Status = 0x01; Outcome = 'Delivered' }
        @{ Status = 0x02; Outcome = 'Delivered' }
        @{ Status = 0x03; Outcome = 'Failed' }
        @{ Status = 0x10; Outcome = 'Delivered' }
        @{ Status = 0x1F; Outcome = 'Delivered' }
        @{ Status = 0x20; Outcome = 'Trying' }
        @{ Status = 0x25; Outcome = 'Trying' }
        @{ Status = 0x26; Outcome = 'Failed' }
        @{ Status = 0x30; Outcome = 'Trying' }
        @{ Status = 0x3F; Outcome = 'Trying' }
        @{ Status = 0x40; Outcome = 'Failed' }
        @{ Status = 0x63; Outcome = 'Failed' }
        @{ Status = 0x7F; Outcome = 'Failed' }
        @{ Status = 0x80; Outcome = 'Failed' }
    ) {
        $pdu = '00' + '06' + '2A' + '0B910100000000F0' + '62014021436580' + '62014021536580' + ('{0:X2}' -f $Status)
        (ConvertFrom-SmsPdu -Pdu $pdu).Outcome | Should -Be $Outcome
    }
}

Describe 'ConvertFrom-SmsPdu: a PDU that can''t be read' {
    It 'calls <Name> malformed, and fills nothing else' -ForEach @(
        @{ Name = 'an empty PDU'; Pdu = '' }
        @{ Name = 'text that is not hexadecimal'; Pdu = 'zz' }
        @{ Name = 'an odd count of digits'; Pdu = '07910' }
        @{ Name = 'a service-centre address cut short'; Pdu = '0791010000' }
        @{ Name = 'a sender cut short'; Pdu = '07910100000000F0040B9101' }
        @{ Name = 'user data shorter than its length'; Pdu = '07910100000000F0040B910100000000F00000620140214365800AE8329BFD06' }
        @{ Name = 'a header longer than the user data'; Pdu = '07910100000000F0440B910100000000F0000862014021436580020A00' }
    ) {
        $sms = ConvertFrom-SmsPdu -Pdu $Pdu

        $sms.Problem | Should -Be 'Malformed'
        $sms.Type | Should -BeNullOrEmpty
        $sms.Address | Should -BeNullOrEmpty
        $sms.Text | Should -BeNullOrEmpty
    }
}

Describe 'The data coding scheme' {
    It 'reads 0x<Hex> as <Alphabet>' -ForEach @(
        @{ Hex = '00'; Alphabet = 'Gsm7'; Class = $null; Compressed = $false; Waiting = $null }
        @{ Hex = '04'; Alphabet = 'Data8'; Class = $null; Compressed = $false; Waiting = $null }
        @{ Hex = '08'; Alphabet = 'Ucs2'; Class = $null; Compressed = $false; Waiting = $null }
        @{ Hex = '0C'; Alphabet = 'Gsm7'; Class = $null; Compressed = $false; Waiting = $null }
        @{ Hex = '10'; Alphabet = 'Gsm7'; Class = 0; Compressed = $false; Waiting = $null }
        @{ Hex = '11'; Alphabet = 'Gsm7'; Class = 1; Compressed = $false; Waiting = $null }
        @{ Hex = '12'; Alphabet = 'Gsm7'; Class = 2; Compressed = $false; Waiting = $null }
        @{ Hex = '13'; Alphabet = 'Gsm7'; Class = 3; Compressed = $false; Waiting = $null }
        @{ Hex = '19'; Alphabet = 'Ucs2'; Class = 1; Compressed = $false; Waiting = $null }
        @{ Hex = '20'; Alphabet = 'Gsm7'; Class = $null; Compressed = $true; Waiting = $null }
        @{ Hex = '48'; Alphabet = 'Ucs2'; Class = $null; Compressed = $false; Waiting = $null }
        @{ Hex = '53'; Alphabet = 'Gsm7'; Class = 3; Compressed = $false; Waiting = $null }
        @{ Hex = '80'; Alphabet = 'Gsm7'; Class = $null; Compressed = $false; Waiting = $null }
        @{ Hex = 'B4'; Alphabet = 'Gsm7'; Class = $null; Compressed = $false; Waiting = $null }
        @{ Hex = 'C0'; Alphabet = 'Gsm7'; Class = $null; Compressed = $false; Waiting = @{ Kind = 'Voicemail'; Active = $false; Store = $false } }
        @{ Hex = 'C8'; Alphabet = 'Gsm7'; Class = $null; Compressed = $false; Waiting = @{ Kind = 'Voicemail'; Active = $true; Store = $false } }
        @{ Hex = 'D9'; Alphabet = 'Gsm7'; Class = $null; Compressed = $false; Waiting = @{ Kind = 'Fax'; Active = $true; Store = $true } }
        @{ Hex = 'E2'; Alphabet = 'Ucs2'; Class = $null; Compressed = $false; Waiting = @{ Kind = 'Email'; Active = $false; Store = $true } }
        @{ Hex = 'EB'; Alphabet = 'Ucs2'; Class = $null; Compressed = $false; Waiting = @{ Kind = 'Other'; Active = $true; Store = $true } }
        @{ Hex = 'F0'; Alphabet = 'Gsm7'; Class = 0; Compressed = $false; Waiting = $null }
        @{ Hex = 'F1'; Alphabet = 'Gsm7'; Class = 1; Compressed = $false; Waiting = $null }
        @{ Hex = 'F4'; Alphabet = 'Data8'; Class = 0; Compressed = $false; Waiting = $null }
        @{ Hex = 'F6'; Alphabet = 'Data8'; Class = 2; Compressed = $false; Waiting = $null }
    ) {
        $coding = & $script:module { param($dcs) Resolve-SmsDataCoding -Dcs $dcs } ([Convert]::ToInt32($Hex, 16))

        $coding.Alphabet | Should -Be $Alphabet
        $coding.Class | Should -Be $Class
        $coding.Compressed | Should -Be $Compressed
        if ($Waiting) {
            $coding.Waiting.Kind | Should -Be $Waiting.Kind
            $coding.Waiting.Active | Should -Be $Waiting.Active
            $coding.Waiting.Store | Should -Be $Waiting.Store
        }
        else {
            $coding.Waiting | Should -BeNullOrEmpty
        }
    }
}

Describe 'The user data header' {
    It 'reads <Name>' -ForEach @(
        @{ Name = 'a long message''s part, one-octet reference'; Header = '00032A0201'; Concat = @{ Reference = 42; Wide = $false; Count = 2; Part = 1 }; National = $false }
        @{ Name = 'a long message''s part, two-octet reference'; Header = '080412340201'; Concat = @{ Reference = 0x1234; Wide = $true; Count = 2; Part = 1 }; National = $false }
        @{ Name = 'a count of 0, ignored'; Header = '00032A0001'; Concat = $null; National = $false }
        @{ Name = 'a part number of 0, ignored'; Header = '00032A0200'; Concat = $null; National = $false }
        @{ Name = 'a part number above the count, ignored'; Header = '00032A0203'; Concat = $null; National = $false }
        @{ Name = 'an element of the wrong length, ignored'; Header = '00042A020100'; Concat = $null; National = $false }
        @{ Name = 'an unknown element, skipped'; Header = '0A02AAAA00032A0201'; Concat = @{ Reference = 42; Wide = $false; Count = 2; Part = 1 }; National = $false }
        @{ Name = 'two such elements: the last counts'; Header = '00030102010003020302'; Concat = @{ Reference = 2; Wide = $false; Count = 3; Part = 2 }; National = $false }
        @{ Name = 'a national language table'; Header = '240101'; Concat = $null; National = $true }
        @{ Name = 'a last element that runs past the header: all ignored'; Header = '00032A020100'; Concat = $null; National = $false }
        @{ Name = 'an element longer than what is left: all ignored'; Header = '24010100052A0201'; Concat = $null; National = $false }
        @{ Name = 'nothing'; Header = ''; Concat = $null; National = $false }
    ) {
        $read = & $script:module { param($octets) ConvertFrom-SmsUserDataHeader -Header $octets } ([Convert]::FromHexString($Header))

        $read.NationalLanguage | Should -Be $National
        if ($Concat) {
            $read.Concat.Reference | Should -Be $Concat.Reference
            $read.Concat.Wide | Should -Be $Concat.Wide
            $read.Concat.Count | Should -Be $Concat.Count
            $read.Concat.Part | Should -Be $Concat.Part
        }
        else {
            $read.Concat | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-SmsPdu' {
    It 'encodes <Name>' -ForEach @(
        @{ Name = 'GSM 7-bit text to an international number'; Number = '+10000000000'; Text = 'hello'; Pdu = '0001000B910100000000F0000005E8329BFD06'; Length = 18 }
        @{ Name = 'a number of unknown type'; Number = '10000000000'; Text = 'hello'; Pdu = '0001000B810100000000F0000005E8329BFD06'; Length = 18 }
        @{ Name = 'an even count of digits'; Number = '1000000000'; Text = 'hello'; Pdu = '0001000A810100000000000005E8329BFD06'; Length = 17 }
        @{ Name = 'an extension character, two septets'; Number = '+10000000000'; Text = '€'; Pdu = '0001000B910100000000F00000029B32'; Length = 15 }
        @{ Name = 'UCS2 text'; Number = '+10000000000'; Text = 'жЯ'; Pdu = '0001000B910100000000F00008040436042F'; Length = 17 }
    ) {
        $parts = @(ConvertTo-SmsPdu -Number $Number -Text $Text)

        $parts.Count | Should -Be 1
        $parts[0].Pdu | Should -Be $Pdu
        $parts[0].Length | Should -Be $Length
        $parts[0].Part | Should -Be 1
        $parts[0].Count | Should -Be 1
    }

    It 'gives the TPDU''s octets as the length, the service centre left out' {
        foreach ($part in ConvertTo-SmsPdu -Number '+10000000000' -Text ('x' * 400) -Reference 9) {
            $part.Length | Should -Be (($part.Pdu.Length / 2) - 1)
        }
    }

    It 'refuses the number <Name>' -ForEach @(
        @{ Name = 'empty'; Number = ' ' }
        @{ Name = 'with letters'; Number = 'abc' }
        @{ Name = 'a + alone'; Number = '+' }
        @{ Name = 'with blanks'; Number = '12 34' }
        @{ Name = 'with a dash'; Number = '+1-555' }
        @{ Name = 'of 21 digits'; Number = '123456789012345678901' }
    ) {
        { ConvertTo-SmsPdu -Number $Number -Text 'hello' -ErrorAction Stop } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'splits <Name>' -ForEach @(
        @{ Name = '160 GSM 7-bit characters into one message'; Text = 'a' * 160; Parts = 1; Alphabet = 'Gsm7' }
        @{ Name = '161 into two: 153 and 8'; Text = 'a' * 161; Parts = 2; Alphabet = 'Gsm7' }
        @{ Name = '306 into two'; Text = 'a' * 306; Parts = 2; Alphabet = 'Gsm7' }
        @{ Name = '307 into three'; Text = 'a' * 307; Parts = 3; Alphabet = 'Gsm7' }
        @{ Name = '70 UCS2 characters into one message'; Text = 'ж' * 70; Parts = 1; Alphabet = 'Ucs2' }
        @{ Name = '71 into two: 67 and 4'; Text = 'ж' * 71; Parts = 2; Alphabet = 'Ucs2' }
        @{ Name = '80 extension characters, 160 septets, into one'; Text = '€' * 80; Parts = 1; Alphabet = 'Gsm7' }
        @{ Name = 'one more GSM character than fits, with an accent of its own'; Text = 'è' * 161; Parts = 2; Alphabet = 'Gsm7' }
    ) {
        $pdus = @(ConvertTo-SmsPdu -Number '+10000000000' -Text $Text -Reference 77)

        $pdus.Count | Should -Be $Parts
        (Measure-SmsText -Text $Text).Parts | Should -Be $Parts
        (Measure-SmsText -Text $Text).Alphabet | Should -Be $Alphabet
        $decoded = @($pdus | ForEach-Object { ConvertFrom-SmsPdu -Pdu $_.Pdu })
        foreach ($i in 0..($pdus.Count - 1)) {
            $pdus[$i].Part | Should -Be ($i + 1)
            $pdus[$i].Count | Should -Be $Parts
            if ($Parts -gt 1) {
                $pdus[$i].Pdu.Substring(2, 2) | Should -Be '41' -Because 'a part carries a user data header'
                $decoded[$i].Concat.Reference | Should -Be 77
                $decoded[$i].Concat.Count | Should -Be $Parts
                $decoded[$i].Concat.Part | Should -Be ($i + 1)
            }
        }
        (-join ($decoded | ForEach-Object Text)) | Should -BeExactly $Text
    }

    It 'packs a part''s text after its header and one fill bit, as 23.038 draws it' {
        $parts = @(ConvertTo-SmsPdu -Number '+10000000000' -Text ('a' * 161) -Reference 7)

        # The second part: 7 septets of header, then 8 'a'.
        $parts[1].Pdu | Should -BeLike ('*0F' + '050003070202' + (ConvertTo-TestPacked -Septets ([int[]][char[]]('a' * 8)) -Fill 1))
    }

    It 'never splits an escaped character from its escape' {
        # 152 septets, then the escape and its septet: 154 don't fit in a part of 153.
        $parts = @(ConvertTo-SmsPdu -Number '+10000000000' -Text (('a' * 152) + '€' + ('b' * 10)))

        $parts.Count | Should -Be 2
        (ConvertFrom-SmsPdu -Pdu $parts[0].Pdu).Text | Should -Be ('a' * 152)
        (ConvertFrom-SmsPdu -Pdu $parts[1].Pdu).Text | Should -Be ('€' + ('b' * 10))
    }

    It 'never splits a surrogate pair' {
        $smile = [char]::ConvertFromUtf32(0x1F600)
        # 66 code units, then a pair: 68 don't fit in a part of 67.
        $parts = @(ConvertTo-SmsPdu -Number '+10000000000' -Text (('ж' * 66) + $smile + ('я' * 5)))

        $parts.Count | Should -Be 2
        (ConvertFrom-SmsPdu -Pdu $parts[0].Pdu).Text | Should -Be ('ж' * 66)
        (ConvertFrom-SmsPdu -Pdu $parts[1].Pdu).Text | Should -Be ($smile + ('я' * 5))
    }

    It 'gives back <Name> once decoded and joined' -ForEach @(
        @{ Name = 'plain text'; Text = 'The quick brown fox jumps over the lazy dog 0123456789' }
        @{ Name = 'the whole default alphabet'; Text = "@£$¥èéùìòÇ`nØø`rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !`"#¤%&'()*+,-./:;<=>?¡ÄÖÑÜ§¿äöñüà" }
        @{ Name = 'every extension character'; Text = "^{}\[~]|€`f" }
        @{ Name = 'a long text across several parts'; Text = ('Hello world, ' * 40) + '€' }
        @{ Name = 'mixed scripts and an emoji'; Text = ('Привет мир 👋 ' * 12) }
    ) {
        $parts = @(ConvertTo-SmsPdu -Number '+10000000000' -Text $Text -Reference 3)
        $entries = for ($i = 0; $i -lt $parts.Count; $i++) {
            [pscustomobject]@{ Index = 20 - $i; Status = 'Sent'; Sms = (ConvertFrom-SmsPdu -Pdu $parts[$i].Pdu) }
        }
        $joined = @(Join-SmsPart -Entry $entries)

        $joined.Count | Should -Be 1
        $joined[0].Text | Should -BeExactly $Text
        $joined[0].Complete | Should -BeTrue
    }

    It 'refuses a text of more than 255 parts, as Measure-SmsText says' {
        $text = 'a' * (153 * 255 + 1)

        (Measure-SmsText -Text $text).TooLong | Should -BeTrue
        (Measure-SmsText -Text ('a' * (153 * 255))).TooLong | Should -BeFalse
        { ConvertTo-SmsPdu -Number '+10000000000' -Text $text -ErrorAction Stop } | Should -Throw -ExceptionType ([System.ArgumentException])
    }
}

Describe 'Measure-SmsText' {
    It 'measures <Name>' -ForEach @(
        @{ Name = 'GSM 7-bit text'; Text = 'hello'; Alphabet = 'Gsm7'; Length = 5; PerPart = 160; Parts = 1 }
        @{ Name = 'an extension character as two'; Text = '€'; Alphabet = 'Gsm7'; Length = 2; PerPart = 160; Parts = 1 }
        @{ Name = 'a long GSM 7-bit text'; Text = 'a' * 161; Alphabet = 'Gsm7'; Length = 161; PerPart = 153; Parts = 2 }
        @{ Name = 'a character outside the alphabet'; Text = 'ж'; Alphabet = 'Ucs2'; Length = 1; PerPart = 70; Parts = 1 }
        @{ Name = 'an emoji as two code units'; Text = [char]::ConvertFromUtf32(0x1F600); Alphabet = 'Ucs2'; Length = 2; PerPart = 70; Parts = 1 }
        @{ Name = 'nothing'; Text = ''; Alphabet = 'Gsm7'; Length = 0; PerPart = 160; Parts = 1 }
    ) {
        $measure = Measure-SmsText -Text $Text

        $measure.Alphabet | Should -Be $Alphabet
        $measure.Length | Should -Be $Length
        $measure.PerPart | Should -Be $PerPart
        $measure.Parts | Should -Be $Parts
        $measure.TooLong | Should -BeFalse
    }
}

Describe 'Join-SmsPart' {
    It 'keeps single messages apart, newest first' {
        $joined = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 1 -Text 'older' -Time ([DateTimeOffset]::new(2026, 10, 1, 9, 0, 0, [TimeSpan]::Zero))
                Get-TestEntry -Index 2 -Text 'newer' -Time ([DateTimeOffset]::new(2026, 10, 2, 9, 0, 0, [TimeSpan]::Zero))
                Get-TestEntry -Index 3 -Text 'no time' -Time $null
            ))

        $joined.Text | Should -Be @('newer', 'older', 'no time')
        $joined[0].Indexes | Should -Be @(2)
        $joined[0].Count | Should -Be 1
        $joined[0].Complete | Should -BeTrue
        $joined[0].Missing | Should -BeNullOrEmpty
    }

    It 'joins the parts in order, whatever their order in the storage' {
        $joined = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 4 -Text 'three' -Reference 9 -Count 3 -Part 3
                Get-TestEntry -Index 7 -Text 'one ' -Reference 9 -Count 3 -Part 1
                Get-TestEntry -Index 5 -Text 'two ' -Reference 9 -Count 3 -Part 2
            ))

        $joined.Count | Should -Be 1
        $joined[0].Text | Should -Be 'one two three'
        $joined[0].Indexes | Should -Be @(7, 5, 4)
        $joined[0].Count | Should -Be 3
        $joined[0].Complete | Should -BeTrue
    }

    It 'never joins <Name>' -ForEach @(
        @{ Name = 'another reference'; Second = @{ Reference = 2 } }
        @{ Name = 'another sender''s parts'; Second = @{ Reference = 1; Address = '10000000000' } }
        @{ Name = 'another count'; Second = @{ Reference = 1; Count = 3 } }
        @{ Name = 'the other size of reference'; Second = @{ Reference = 1; Wide = $true } }
    ) {
        $joined = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 1 -Text 'a' -Reference 1 -Count 2 -Part 1
                Get-TestEntry -Index 2 -Text 'b' -Part 2 @Second
            ))

        $joined.Count | Should -Be 2
    }

    It 'keeps the first of a part stored twice with another text' {
        $joined = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 1 -Text 'one ' -Reference 1 -Part 1
                Get-TestEntry -Index 2 -Text 'two' -Reference 1 -Part 2
                Get-TestEntry -Index 3 -Text 'uno ' -Reference 1 -Part 1
            ))

        $joined[0].Text | Should -Be 'one two'
    }

    It 'counts a part stored twice once, and keeps both places' {
        $joined = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 1 -Text 'one ' -Reference 1 -Part 1
                Get-TestEntry -Index 2 -Text 'two' -Reference 1 -Part 2
                Get-TestEntry -Index 3 -Text 'one ' -Reference 1 -Part 1
            ))

        $joined.Count | Should -Be 1
        $joined[0].Text | Should -Be 'one two'
        $joined[0].Indexes | Should -Be @(1, 3, 2)
    }

    It 'marks the parts missing: <Name>' -ForEach @(
        @{ Name = 'in the middle'; Have = @(1, 3); Text = 'p1 … p3'; Missing = @(2) }
        @{ Name = 'the first'; Have = @(2, 3); Text = '… p2p3'; Missing = @(1) }
        @{ Name = 'the last ones'; Have = @(1); Text = 'p1 …'; Missing = @(2, 3) }
    ) {
        $entries = foreach ($part in $Have) { Get-TestEntry -Index $part -Text "p$part" -Reference 5 -Count 3 -Part $part }
        $joined = @(Join-SmsPart -Entry @($entries))

        $joined[0].Text | Should -Be $Text
        $joined[0].Missing | Should -Be $Missing
        $joined[0].Complete | Should -BeFalse
        $joined[0].Count | Should -Be 3
    }

    It 'calls a message unread when any part is' {
        $joined = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 1 -Status 'Read' -Reference 1 -Part 1
                Get-TestEntry -Index 2 -Status 'Unread' -Reference 1 -Part 2
            ))

        $joined[0].Status | Should -Be 'Unread'
    }

    It 'dates a message by its first part, else by its earliest' {
        $early = [DateTimeOffset]::new(2026, 10, 1, 8, 0, 0, [TimeSpan]::Zero)
        $late = [DateTimeOffset]::new(2026, 10, 1, 9, 0, 0, [TimeSpan]::Zero)
        $first = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 1 -Reference 1 -Part 1 -Time $late
                Get-TestEntry -Index 2 -Reference 1 -Part 2 -Time $early
            ))
        $earliest = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 1 -Reference 1 -Count 3 -Part 2 -Time $late
                Get-TestEntry -Index 2 -Reference 1 -Count 3 -Part 3 -Time $early
            ))

        $first[0].Time | Should -Be $late
        $earliest[0].Time | Should -Be $early
    }

    It 'keeps a PDU that can''t be read apart' {
        $joined = @(Join-SmsPart -Entry @(
                Get-TestEntry -Index 1 -Problem 'Malformed' -Text $null -Address $null -Time $null
                Get-TestEntry -Index 2 -Text 'fine'
            ))

        $joined.Count | Should -Be 2
        @($joined | Where-Object Problem -EQ 'Malformed').Indexes | Should -Be @(1)
    }

    It 'gives no text when no part has any' {
        @(Join-SmsPart -Entry @(Get-TestEntry -Index 1 -Text $null))[0].Text | Should -BeNullOrEmpty
    }

    It 'gives nothing for an empty storage' {
        @(Join-SmsPart -Entry @()).Count | Should -Be 0
    }
}

Describe 'ConvertFrom-AtMessageList' {
    It 'reads the messages AT+CMGL lists, played through the channel' {
        $entries = @(ConvertFrom-AtMessageList -Lines (Get-FixtureAnswer -Name 'cmgl.pdu.txt'))

        $entries.Index | Should -Be @(1, 2, 3)
        $entries.Status | Should -Be @('Read', 'Unread', 'Unread')
        ($entries | ForEach-Object Length) | Should -Be @(24, 34, 34)
        foreach ($entry in $entries) {
            ($entry.Pdu.Length / 2) - 8 | Should -Be $entry.Length -Because 'the length counts the TPDU, not the service centre'
        }
    }

    It 'gives what the user reads once decoded and joined' {
        $entries = foreach ($entry in ConvertFrom-AtMessageList -Lines (Get-FixtureAnswer -Name 'cmgl.pdu.txt')) {
            [pscustomobject]@{ Index = $entry.Index; Status = $entry.Status; Sms = ConvertFrom-SmsPdu -Pdu $entry.Pdu }
        }
        $joined = @(Join-SmsPart -Entry @($entries))

        $joined.Count | Should -Be 2
        $long = $joined | Where-Object Count -EQ 2
        $long.Text | Should -Be 'Part onePart two'
        $long.Address | Should -Be 'Operator'
        $long.Indexes | Should -Be @(3, 2)
        $long.Status | Should -Be 'Unread'
        ($joined | Where-Object Count -EQ 1).Text | Should -Be 'hello'
    }

    It 'leaves out a header without its PDU, and ignores other lines' {
        $entries = @(ConvertFrom-AtMessageList -Lines @(
                '+CMGL: 1,0,,24'
                '+CMTI: "MT",4'
                '+CMGL: 2,1,,24'
                '07910100000000f0040b910100000000f000006201402143658005e8329bfd06'
                'noise'
            ))

        $entries.Count | Should -Be 1
        $entries[0].Index | Should -Be 2
        $entries[0].Pdu | Should -Be '07910100000000F0040B910100000000F000006201402143658005E8329BFD06'
    }

    It 'leaves out a header without its index and status: <Name>' -ForEach @(
        @{ Name = 'an index alone'; Header = '+CMGL: 3' }
        @{ Name = 'nothing'; Header = '+CMGL:' }
        @{ Name = 'an index that is no number'; Header = '+CMGL: x,0,,24' }
    ) {
        @(ConvertFrom-AtMessageList -Lines $Header, (Get-TestDeliverPdu) -ErrorAction Stop).Count | Should -Be 0
    }

    It 'reads an empty AT+CMGR answer without failing' {
        { ConvertFrom-AtMessageList -Lines '+CMGR:', (Get-TestDeliverPdu) -Index 7 -ErrorAction Stop } | Should -Not -Throw
    }

    It 'reads a status it doesn''t know as none' {
        @(ConvertFrom-AtMessageList -Lines '+CMGL: 5,7,,24', (Get-TestDeliverPdu))[0].Status | Should -BeNullOrEmpty
    }

    It 'reads AT+CMGR''s answer for the index given' {
        $entry = @(ConvertFrom-AtMessageList -Lines '+CMGR: 0,,24', (Get-TestDeliverPdu) -Index 7)

        $entry.Count | Should -Be 1
        $entry[0].Index | Should -Be 7
        $entry[0].Status | Should -Be 'Unread'
        $entry[0].Length | Should -Be 24
    }

    It 'gives nothing for an empty storage' {
        @(ConvertFrom-AtMessageList -Lines @()).Count | Should -Be 0
        @(ConvertFrom-AtMessageList -Lines (Get-FixtureAnswer -Name 'cmgl.empty.txt' -Folder device)).Count | Should -Be 0
    }

    It 'reads the device''s messages, with its blanks, and gives back the texts sent' {
        $listed = @(ConvertFrom-AtMessageList -Lines (Get-FixtureAnswer -Name 'cmgl.device.txt' -Folder device))
        $entries = foreach ($entry in $listed) {
            [pscustomobject]@{ Index = $entry.Index; Status = $entry.Status; Pdu = $entry.Pdu; Sms = ConvertFrom-SmsPdu -Pdu $entry.Pdu }
        }
        $joined = @(Join-SmsPart -Entry @($entries) | Sort-Object { $_.Indexes[0] })

        $listed.Count | Should -Be 4
        @($listed | ForEach-Object Status) | Should -Be @('Read', 'Read', 'Read', 'Read')
        @($listed | ForEach-Object Length) | Should -Be @(62, 159, 74, 105)
        $joined.Count | Should -Be 3
        # As the phone sent them: the first without its last full stop, the others with a line end.
        $joined[0].Text | Should -BeExactly 'Prova SMS 1: testo semplice per il test del modem'
        $joined[1].Text | Should -BeExactly ('Prova SMS 2: messaggio lungo per verificare la ricomposizione delle parti. Contiene lettere accentate come è, à, ù, ò e il simbolo €, oltre a parentesi [quadre] e {graffe}. Fine della prova numero due.' + "`r`n")
        $joined[1].Indexes | Should -Be @(2, 3)
        $joined[2].Text | Should -BeExactly ("Prova SMS 3: emoji $([char]::ConvertFromUtf32(0x1F600)) e cirillico Привет." + "`r`n")
        $joined[2].Indexes | Should -Be @(4)
        foreach ($message in $joined) {
            $message.Address | Should -Be '+10000000000'
            $message.Complete | Should -BeTrue
            $message.Time.Offset | Should -Be ([TimeSpan]::FromHours(2))
        }
    }

    It 'reads the device''s answer to AT+CMGR' {
        $entry = @(ConvertFrom-AtMessageList -Lines (Get-FixtureAnswer -Name 'cmgr.device.txt' -Folder device) -Index 2)

        $entry.Count | Should -Be 1
        $entry[0].Status | Should -Be 'Unread'
        $entry[0].Length | Should -Be 48
        (ConvertFrom-SmsPdu -Pdu $entry[0].Pdu).Text | Should -BeExactly ('Prova SMS 4: con i dati accesi.' + "`r`n")
    }
}

Describe 'ConvertFrom-AtMessageStorage' {
    It 'reads the captured storage: "MT", 70 places for each use' {
        $storage = ConvertFrom-AtMessageStorage -Lines (Get-FixtureAnswer -Name 'cpms.sim.txt' -Folder device)

        foreach ($use in $storage.Read, $storage.Write, $storage.Receive) {
            $use.Memory | Should -Be 'MT'
            $use.Used | Should -Be 0
            $use.Total | Should -Be 70
        }
    }

    It 'reads three storages apart' {
        $storage = ConvertFrom-AtMessageStorage -Lines '+CPMS: "SM",3,50,"ME",1,100,"SM",3,50'

        $storage.Read.Memory | Should -Be 'SM'
        $storage.Read.Used | Should -Be 3
        $storage.Write.Memory | Should -Be 'ME'
        $storage.Write.Total | Should -Be 100
        $storage.Receive.Memory | Should -Be 'SM'
    }

    It 'gives nothing for <Name>' -ForEach @(
        @{ Name = 'no +CPMS line'; Lines = @('OK') }
        @{ Name = 'the set form''s counts alone'; Lines = @('+CPMS: 3,50,3,50,3,50') }
        @{ Name = 'a count that is no number'; Lines = @('+CPMS: "SM",x,50,"SM",3,50,"SM",3,50') }
    ) {
        ConvertFrom-AtMessageStorage -Lines $Lines | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-AtNewMessage' {
    It 'reads <Line>' -ForEach @(
        @{ Line = '+CMTI: "ME",3'; Memory = 'ME'; Index = 3 }
        @{ Line = '+CMTI: "SM", 12'; Memory = 'SM'; Index = 12 }
        @{ Line = '+CMTI:"MT",0'; Memory = 'MT'; Index = 0 }
        # As the device sends it (AT-COMMANDS section 9).
        @{ Line = '+CMTI: "SM", 2'; Memory = 'SM'; Index = 2 }
    ) {
        $notice = ConvertFrom-AtNewMessage -Line $Line

        $notice.Memory | Should -Be $Memory
        $notice.Index | Should -Be $Index
    }

    It 'gives nothing for <Line>' -ForEach @(
        @{ Line = '+CMTI: "MT"' }
        @{ Line = '+CMTI: "MT",x' }
        @{ Line = '+CREG: 1' }
        @{ Line = '' }
    ) {
        ConvertFrom-AtNewMessage -Line $Line | Should -BeNullOrEmpty
    }
}

Describe 'What is new' {
    BeforeAll {
        $script:one = Get-TestDeliverPdu -UserData '05E8329BFD06'
        $script:two = Get-TestDeliverPdu -Time '62014021436680' -UserData '05E8329BFD06'
        $script:three = Get-TestDeliverPdu -Time '62014021436780' -UserData '05E8329BFD06'
        $script:f1 = Get-SmsFingerprint -Pdu $script:one
        $script:f2 = Get-SmsFingerprint -Pdu $script:two
        $script:f3 = Get-SmsFingerprint -Pdu $script:three
    }

    It 'fingerprints a part by its whole PDU, in any case, telling nothing of it' {
        $script:f1 | Should -Match '^[0-9A-F]{64}$'
        Get-SmsFingerprint -Pdu $script:one.ToLowerInvariant() | Should -Be $script:f1
        Get-SmsFingerprint -Pdu " $($script:one)`r`n" | Should -Be $script:f1 -Because 'blanks around a PDU are no part of it'
        $script:f2 | Should -Not -Be $script:f1 -Because 'another time stamp is another message'
        $script:f1 | Should -Not -Match '0100000000'
    }

    It 'keeps <Name>' -ForEach @(
        @{ Name = 'what the modem reports unread'; Before = @(); Stored = @(@('one', 'Unread'), @('two', 'Read')); Opened = @(); After = @('f1') }
        @{ Name = 'what was new and is still stored, though the listing marked it read'; Before = @('f2'); Stored = @(@('one', 'Read'), @('two', 'Read')); Opened = @(); After = @('f2') }
        @{ Name = 'nothing of what is no longer stored'; Before = @('f3'); Stored = @(, @('one', 'Read')); Opened = @(); After = @() }
        @{ Name = 'nothing the user opened, unread or not'; Before = @('f2'); Stored = @(@('one', 'Unread'), @('two', 'Read')); Opened = @('f1', 'f2'); After = @() }
        @{ Name = 'nothing for an empty storage'; Before = @('f1', 'f2'); Stored = @(); Opened = @(); After = @() }
        @{ Name = 'what was new, whatever the case of its fingerprint'; Before = @('f2 lower'); Stored = @(@('one', 'Read'), @('two', 'Read')); Opened = @('f2 lower'); After = @() }
        @{ Name = 'what was new and still stored, its fingerprint in lower case'; Before = @('f2 lower'); Stored = @(, @('two', 'Read')); Opened = @(); After = @('f2') }
    ) {
        $names = @{ one = $script:one; two = $script:two; three = $script:three }
        $prints = @{ f1 = $script:f1; f2 = $script:f2; f3 = $script:f3; 'f2 lower' = $script:f2.ToLowerInvariant() }
        $entries = foreach ($pair in $Stored) { [pscustomobject]@{ Pdu = $names[$pair[0]]; Status = $pair[1] } }
        $result = Update-SmsUnread -Unread @($Before | ForEach-Object { $prints[$_] }) -Entry @($entries) -Opened @($Opened | ForEach-Object { $prints[$_] })

        @($result) | Should -Be @(@($After | ForEach-Object { $prints[$_] }) | Sort-Object)
    }

    It 'joins a message''s fingerprints, part by part' {
        $entries = @(
            [pscustomobject]@{ Index = 1; Status = 'Unread'; Pdu = $script:one; Sms = ConvertFrom-SmsPdu -Pdu $script:one }
        )
        @(Join-SmsPart -Entry $entries)[0].Fingerprints | Should -Be @($script:f1)
    }

    It 'reads back the fingerprints it wrote, encrypted for the user' {
        $path = Join-Path $TestDrive 'sms-new.dat'
        Export-SmsUnread -Fingerprint @($script:f1, $script:f2) -Path $path -Confirm:$false

        @(Import-SmsUnread -Path $path) | Should -Be @($script:f1, $script:f2)
        Get-Content -LiteralPath $path -Raw | Should -Not -Match $script:f1 -Because 'the file is encrypted'
        Export-SmsUnread -Fingerprint @() -Path $path -Confirm:$false
        @(Import-SmsUnread -Path $path).Count | Should -Be 0
    }

    It 'gives none without a file' {
        $warnings = $null
        @(Import-SmsUnread -Path (Join-Path $TestDrive 'none.dat') -WarningVariable warnings -WarningAction SilentlyContinue).Count | Should -Be 0
        $warnings.Count | Should -Be 0 -Because 'no list yet is nothing to warn about'
    }

    It 'gives none, with a warning, for <Name>' -ForEach @(
        @{ Name = 'a file that is not encrypted'; Content = '["AB"]'; Failure = 'CryptographicException' }
        @{ Name = 'a damaged file'; Content = '01000000d08c9ddf'; Failure = 'CryptographicException' }
        @{ Name = 'a list that is not of fingerprints'; Written = @('AB'); Failure = 'FormatException' }
        @{ Name = 'a fingerprint too short'; Written = @('0123456789ABCDEF'); Failure = 'FormatException' }
    ) {
        $path = Join-Path $TestDrive 'bad.dat'
        if ($Written) {
            Export-SmsUnread -Fingerprint $Written -Path $path -Confirm:$false
        }
        else {
            Set-Content -LiteralPath $path -Value $Content
        }
        $warnings = $null
        $result = @(Import-SmsUnread -Path $path -WarningVariable warnings -WarningAction SilentlyContinue)

        $result.Count | Should -Be 0
        $warnings.Count | Should -Be 1
        "$warnings" | Should -Match $Failure
    }
}

Describe 'Which SIM a message came in on' {
    BeforeAll {
        $script:one = Get-TestDeliverPdu -UserData '05E8329BFD06'
        $script:two = Get-TestDeliverPdu -Time '62014021436680' -UserData '05E8329BFD06'
        $script:f1 = Get-SmsFingerprint -Pdu $script:one
        $script:f2 = Get-SmsFingerprint -Pdu $script:two
        $script:simA = 'A' * 64
        $script:simB = 'B' * 64
    }

    It '<Name>' -ForEach @(
        @{ Name = 'gives a part listed unread the SIM in use'; Before = @(); Stored = @(@('one', 'Unread'), @('two', 'Read')); Sim = 'A'; Kind = 'Esim'; Profile = 'Travel'; After = @(, @('f1', 'A', 'Esim', 'Travel')) }
        @{ Name = 'gives no SIM to a part already read when first seen'; Before = @(); Stored = @(, @('two', 'Read')); Sim = 'A'; Kind = 'Usim'; Profile = ''; After = @() }
        @{ Name = 'keeps the SIM a part came in on, listed unread again with another in use'; Before = @(, @('f1', 'A', 'Esim', 'Travel')); Stored = @(, @('one', 'Unread')); Sim = 'B'; Kind = 'Esim'; Profile = 'Test'; After = @(, @('f1', 'A', 'Esim', 'Travel')) }
        @{ Name = 'gives no SIM without the SIM in use'; Before = @(); Stored = @(, @('one', 'Unread')); Sim = ''; Kind = ''; Profile = ''; After = @() }
        @{ Name = 'renames the SIM in use''s parts, not another''s'; Before = @(@('f1', 'A', 'Esim', 'Travel'), @('f2', 'B', 'Esim', 'Test')); Stored = @(); Sim = 'A'; Kind = 'Esim'; Profile = 'Away'; After = @(@('f1', 'A', 'Esim', 'Away'), @('f2', 'B', 'Esim', 'Test')) }
        @{ Name = 'keeps a part''s name when the SIM in use has none'; Before = @(, @('f1', 'A', 'Esim', 'Travel')); Stored = @(); Sim = 'A'; Kind = 'Esim'; Profile = ''; After = @(, @('f1', 'A', 'Esim', 'Travel')) }
        @{ Name = 'keeps the parts another slot''s storage holds'; Before = @(, @('f1', 'B', 'Usim', '')); Stored = @(, @('two', 'Unread')); Sim = 'A'; Kind = 'Esim'; Profile = 'Travel'; After = @(@('f1', 'B', 'Usim', ''), @('f2', 'A', 'Esim', 'Travel')) }
        @{ Name = 'knows a part whatever the case of its fingerprint'; Before = @(, @('f1 lower', 'A', 'Esim', 'Travel')); Stored = @(, @('one', 'Unread')); Sim = 'B'; Kind = 'Esim'; Profile = 'Test'; After = @(, @('f1 lower', 'A', 'Esim', 'Travel')) }
    ) {
        $names = @{ one = $script:one; two = $script:two }
        $prints = @{ f1 = $script:f1; f2 = $script:f2; 'f1 lower' = $script:f1.ToLowerInvariant() }
        $sims = @{ A = $script:simA; B = $script:simB; '' = '' }
        $owner = foreach ($item in $Before) { [pscustomobject]@{ Message = $prints[$item[0]]; Sim = $sims[$item[1]]; Kind = $item[2]; Name = $item[3] } }
        $entries = foreach ($pair in $Stored) { [pscustomobject]@{ Pdu = $names[$pair[0]]; Status = $pair[1] } }

        $result = @(Update-SmsOwner -Owner @($owner) -Entry @($entries) -Sim $sims[$Sim] -Kind $Kind -Name $Profile)

        @($result | ForEach-Object { "$($_.Message)|$($_.Sim)|$($_.Kind)|$($_.Name)" }) |
            Should -Be @($After | ForEach-Object { "$($prints[$_[0]])|$($sims[$_[1]])|$($_[2])|$($_[3])" })
    }

    It 'keeps the newest 1000 parts' {
        $owner = foreach ($number in 1..1000) { [pscustomobject]@{ Message = $number.ToString('X64'); Sim = $script:simA; Kind = 'Usim'; Name = '' } }

        $result = @(Update-SmsOwner -Owner @($owner) -Entry @([pscustomobject]@{ Pdu = $script:one; Status = 'Unread' }) -Sim $script:simB -Kind Esim -Name 'Travel')

        $result.Count | Should -Be 1000
        $result[0].Message | Should -Be (2).ToString('X64') -Because 'the oldest is forgotten first'
        $result[-1].Message | Should -Be $script:f1
    }

    It 'reads back the parts and SIMs it wrote, encrypted for the user' {
        $path = Join-Path $TestDrive 'sms-sim.dat'
        $owner = @(
            [pscustomobject]@{ Message = $script:f1; Sim = $script:simA; Kind = 'Esim'; Name = 'Travel' }
            [pscustomobject]@{ Message = $script:f2; Sim = $script:simB; Kind = 'Usim'; Name = '' }
        )
        Export-SmsOwner -Owner $owner -Path $path -Confirm:$false

        $read = @(Import-SmsOwner -Path $path)
        @($read | ForEach-Object { "$($_.Message)|$($_.Sim)|$($_.Kind)|$($_.Name)" }) | Should -Be @("$($script:f1)|$($script:simA)|Esim|Travel", "$($script:f2)|$($script:simB)|Usim|")
        Get-Content -LiteralPath $path -Raw | Should -Not -Match 'Travel' -Because 'the file is encrypted'
        Export-SmsOwner -Owner @() -Path $path -Confirm:$false
        @(Import-SmsOwner -Path $path).Count | Should -Be 0
    }

    It 'gives none without a file' {
        $warnings = $null
        @(Import-SmsOwner -Path (Join-Path $TestDrive 'none-sim.dat') -WarningVariable warnings -WarningAction SilentlyContinue).Count | Should -Be 0
        $warnings.Count | Should -Be 0 -Because 'nothing remembered yet is nothing to warn about'
    }

    It 'gives none, with a warning, for <Name>' -ForEach @(
        @{ Name = 'a file that is not encrypted'; Content = '[]'; Failure = 'CryptographicException' }
        @{ Name = 'a list without SIMs'; Written = @(, @{ Message = 'F' * 64; Kind = 'Usim'; Name = '' }); Failure = 'FormatException' }
        @{ Name = 'a part''s fingerprint too short'; Written = @(, @{ Message = 'AB'; Sim = 'F' * 64; Kind = 'Usim'; Name = '' }); Failure = 'FormatException' }
        @{ Name = 'another kind of SIM'; Written = @(, @{ Message = 'F' * 64; Sim = 'F' * 64; Kind = 'Other'; Name = '' }); Failure = 'FormatException' }
    ) {
        $path = Join-Path $TestDrive 'bad-sim.dat'
        if ($Written) {
            Export-SmsOwner -Owner @($Written | ForEach-Object { [pscustomobject]$_ }) -Path $path -Confirm:$false
        }
        else {
            Set-Content -LiteralPath $path -Value $Content
        }
        $warnings = $null
        $result = @(Import-SmsOwner -Path $path -WarningVariable warnings -WarningAction SilentlyContinue)

        $result.Count | Should -Be 0
        $warnings.Count | Should -Be 1
        "$warnings" | Should -Match $Failure
    }
}
