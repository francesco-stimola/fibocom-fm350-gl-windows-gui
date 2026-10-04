# The app's log: rolling daily files, every line redacted before it is written. Design:
# docs/ARCHITECTURE.md -> Settings and logs; rule: CLAUDE.md -> No identifiers in logs.

# Days of log kept, and the most one day's file may grow to: a loop gone wrong can't fill the disk.
$script:LogDaysKept = 14
$script:LogMaxBytesPerDay = 10MB
$script:LogLimitNotice = 'The log reached its daily limit; nothing more is written today.'

function Test-LogLimitReached {
    # Whether a log file already ends with the daily-limit notice.
    param([string] $Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $length = [int][Math]::Min(512, $stream.Length)
        [void]$stream.Seek(-$length, [System.IO.SeekOrigin]::End)
        $buffer = [byte[]]::new($length)
        [void]$stream.Read($buffer, 0, $length)
        [System.Text.Encoding]::UTF8.GetString($buffer).Contains($script:LogLimitNotice)
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertTo-RedactedText {
    <#
    .SYNOPSIS
        Removes identifiers and secrets from text bound for the log.
    .DESCRIPTION
        Line by line, whatever the text is - a command, an answer, an unsolicited code, a message
        built around them:
        - secrets: the PIN of AT+CPIN= and AT+CPWD=; the password of AT+CLCK=; the user and
          password of AT+CGAUTH= and of a +CGAUTH: answer;
        - IMEI, IMSI, ICCID, EID: any run of 14 digits or more;
        - phone numbers: quoted runs of 7 digits or more, with or without '+';
        - the module serial number of +CFSN: and the EID of +EID:;
        - location: the quoted TAC, cell identity and routing area of registration reports, and
          the TAC and cell identity of +GTCCINFO cell lines - unless they hold the modem's "not
          known" pattern;
        - message content: the text of a +CUSD: reply, and lines that are only hexadecimal (a
          message PDU);
        - the eSIM: the APDUs of AT+CGLA= and of a +CGLA: answer, which can carry the EID and
          ICCIDs; an activation code ('LPA:...'), a secret.
    .EXAMPLE
        ConvertTo-RedactedText -Text 'AT+CPIN="1234"'

        AT+CPIN=***
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Text
    )

    $notKnown = '^0*F*$'
    $redacted = foreach ($line in $Text -split '\r?\n') {
        # Secrets in commands and answers.
        # An argument is a quoted string or a run without blanks, commas or semicolons.
        $line = $line -replace '(?i)(\+(?:CPIN|CPWD)\s*=)\s*(?:"[^"]*"|[^\s;",]*)(?:\s*,\s*(?:"[^"]*"|[^\s;",]*))*', '$1***'
        $line = $line -replace '(?i)(\+CLCK\s*=\s*"[^"]*"\s*,\s*\d+)\s*,\s*(?:"[^"]*"|[^\s;",]*)', '$1,***'
        $line = $line -replace '(?i)(\+CGAUTH\s*[=:]\s*\d+\s*,\s*\d+)(?:\s*,\s*(?:"[^"]*"|[^\s;",]*))+', '$1,***'
        $line = $line -replace '(?i)\bLPA:\S*', 'LPA:***'
        # The eSIM's APDUs, in a command and in its answer.
        $line = $line -replace '(?i)(\+CGLA\s*=\s*\d+\s*,\s*\d+\s*,\s*)"?[0-9A-F]*"?', '$1<apdu>'
        $line = $line -replace '(?i)(\+CGLA\s*:\s*\d+\s*,\s*)"?[0-9A-F]*"?', '$1<apdu>'
        # Identifiers.
        $line = $line -replace '(?<![0-9A-Za-z])\d{14,}[Ff]?(?![0-9A-Za-z])', '<id>'
        $line = $line -replace '"\+?\d{7,}"', '"<number>"'
        $line = $line -replace '(?i)^(\s*\+(?:CFSN|EID)\s*:).*$', '$1 <id>'
        # Location.
        if ($line -match '(?i)^\s*\+C(?:5G|E|G)?REG\s*:') {
            $line = [regex]::Replace($line, '"([0-9A-Fa-f]+)"', {
                    param($match)
                    if ($match.Groups[1].Value -match $notKnown) { $match.Value } else { '"<loc>"' }
                })
        }
        elseif ($line -match '^\s*[12],\d+,') {
            $fields = $line.Split(',')
            foreach ($position in 4, 5) {
                if ($fields.Count -gt $position -and $fields[$position] -and $fields[$position] -notmatch $notKnown) {
                    $fields[$position] = '<loc>'
                }
            }
            $line = $fields -join ','
        }
        # Message content.
        $line = $line -replace '(?i)^(\s*\+CUSD\s*:\s*\d+)\s*,.*$', '$1,***'
        $line = $line -replace '^\s*[0-9A-Fa-f]{20,}\s*$', '<pdu>'
        $line
    }
    $redacted -join [Environment]::NewLine
}

function Write-AppLog {
    <#
    .SYNOPSIS
        Appends a redacted line to today's log file.
    .DESCRIPTION
        Logs live under %LOCALAPPDATA%\fibocom-fm350-gl-windows-gui\logs\, one file per day
        (fm350-<yyyy-MM-dd>.log); the 14 newest are kept. Every message goes through
        ConvertTo-RedactedText first. A day's file stops growing at 10 MB, with one line saying
        so. Timestamps are ISO 8601 with the UTC offset, in the invariant culture. The file is
        opened for each line and closed at once: the log holds no handle.
    .EXAMPLE
        Write-AppLog -Level Info -Message 'Context 1 active'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string] $Level = 'Info',

        [string] $Folder = (Get-AppDataPath -Name 'logs' -Local),

        # The time to stamp; now by default. Tests pass their own.
        [DateTimeOffset] $Time = [DateTimeOffset]::Now
    )

    $invariant = [cultureinfo]::InvariantCulture
    $path = Join-Path -Path $Folder -ChildPath "fm350-$($Time.ToString('yyyy-MM-dd', $invariant)).log"
    $isNewFile = -not (Test-Path -LiteralPath $path -PathType Leaf)
    if ($isNewFile) {
        [void](New-Item -ItemType Directory -Path $Folder -Force)
        # A new day: drop the oldest files beyond the ones kept.
        Get-ChildItem -LiteralPath $Folder -Filter 'fm350-*.log' -File |
            Sort-Object -Property Name -Descending |
            Select-Object -Skip ($script:LogDaysKept - 1) |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    elseif ((Get-Item -LiteralPath $path).Length -ge $script:LogMaxBytesPerDay) {
        return
    }

    $stamp = $Time.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', $invariant)
    $text = (ConvertTo-RedactedText -Text $Message) -replace '\r?\n', "$([Environment]::NewLine)    "
    $entry = "$stamp $($Level.ToUpperInvariant().PadRight(7)) $text"
    if (-not $isNewFile -and (Get-Item -LiteralPath $path).Length + $entry.Length -ge $script:LogMaxBytesPerDay) {
        if (Test-LogLimitReached -Path $path) {
            return
        }
        $entry = "$stamp WARNING $script:LogLimitNotice"
    }
    [System.IO.File]::AppendAllText($path, "$entry$([Environment]::NewLine)", [System.Text.UTF8Encoding]::new($false))
}
