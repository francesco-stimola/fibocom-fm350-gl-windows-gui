# The serial transport: argument checks and the failure to open a port that doesn't exist. The
# real port is exercised only by the Hardware test, on purpose (docs/SETUP.md).

BeforeDiscovery {
    $script:atPort = $env:FM350_AT_PORT
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Open-SerialAtTransport' {
    It 'refuses port name <PortName>' -ForEach @(
        @{ PortName = 'COM0' }
        @{ PortName = 'COM1000' }
        @{ PortName = 'LPT1' }
        @{ PortName = 'COM' }
        @{ PortName = '\\.\COM5' }
    ) {
        { Open-SerialAtTransport -PortName $PortName -ErrorAction Stop } |
            Should -Throw -ExceptionType ([System.Management.Automation.ParameterBindingException])
    }

    It 'fails on a port that does not exist' {
        $absent = 250..999 | ForEach-Object { "COM$_" } |
            Where-Object { $_ -notin [System.IO.Ports.SerialPort]::GetPortNames() } |
            Select-Object -First 1
        { Open-SerialAtTransport -PortName $absent -ErrorAction Stop } | Should -Throw
    }
}

# Needs an FM350 on $env:FM350_AT_PORT and this app not running (it would hold the port).
Describe 'Serial transport on a real FM350' -Tag Hardware -Skip:(-not $script:atPort) {
    It 'opens the AT port, initializes the channel and gets an answer' {
        $channel = New-AtChannel -Transport (Open-SerialAtTransport -PortName $env:FM350_AT_PORT)
        try {
            (Initialize-AtChannel -Channel $channel -TimeoutMs 3000).Status | Should -Be 'OK'
            (Invoke-AtCommand -Channel $channel -Command 'AT+CGMM?' -TimeoutMs 3000).Status | Should -Be 'OK'
        }
        finally {
            Close-AtChannel -Channel $channel
        }
    }
}
