# A stand-in for lpac in the tests (tests/Esim.Tests.ps1): it speaks lpac's stdio protocol
# (docs/AT-COMMANDS.md section 8) on its standard input and output, so the real process plumbing
# - arguments, environment, one line each way, the end - is tested without lpac.
#
# The first argument picks what it does:
#   echo ...  sends connect, waits for its answer, then a result whose data holds the arguments,
#             lpac's variables it sees, and the answer it got
#   hang      writes nothing and waits for a minute, unless stopped
#   exit <n>  ends at once with exit code <n>, having written nothing
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8

function Send-Line {
    param([string] $Line)
    [Console]::Out.Write($Line + "`n")
    [Console]::Out.Flush()
}

switch ($Rest[0]) {
    'hang' {
        Start-Sleep -Seconds 60
        exit 0
    }
    'exit' {
        exit ([int]$Rest[1])
    }
    default {
        Send-Line -Line '{"type":"apdu","payload":{"func":"connect","param":null}}'
        $answer = [Console]::In.ReadLine()
        $seen = [ordered]@{}
        foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator() | Sort-Object Key) {
            if ($entry.Key -like 'LPAC_*' -or $entry.Key -like 'LIBEUICC_*') {
                $seen[$entry.Key] = $entry.Value
            }
        }
        $data = [ordered]@{ arguments = [string[]]@($Rest); environment = $seen; answer = $answer }
        Send-Line -Line ([ordered]@{ type = 'lpa'; payload = [ordered]@{ code = 0; message = 'success'; data = $data } } | ConvertTo-Json -Compress -Depth 6)
        exit 0
    }
}
