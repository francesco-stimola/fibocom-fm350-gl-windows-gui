# The FCC lock: the three reads, the diagnosis matrix, and the unlock sequence on the simulated
# modem - our module is unlocked already, so this is where the unlock path is proven.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    . "$PSScriptRoot/FixtureAnswer.ps1"

    $script:readCommand = 'AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?'
    $script:unlockCommands = @('AT+GTFCCLOCKMODE=0', 'AT+GTFCCLOCKSTATE=0', 'AT+GTFCCEFFSTATUS=0,0', 'AT&W', 'AT+CFUN=1,1')

    # A simulated modem that reads as locked and takes the unlock commands; the restart makes it
    # leave USB.
    function Get-LockedModem {
        $modem = New-SimulatedModem -Fixture "$PSScriptRoot/fixtures/documented/fcc.locked.txt"
        foreach ($command in $script:unlockCommands) {
            $modem.SetAnswer($command, @('OK'))
        }
        # Documented as read-only: its set form answers ERROR.
        $modem.SetAnswer('AT+GTFCCEFFSTATUS=0,0', @('ERROR'))
        $modem.Script('AT+CFUN=1,1', @{ Vanish = $true })
        $modem
    }

    function Get-SentCommand {
        param($Modem)
        @($Modem.Received | Where-Object { $_ -notin 'ATE1', 'AT+CMEE=1' })
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'ConvertFrom-AtFccLock' {
    It 'reads the captured unlocked module: mode 0, state 0, no lock in effect' {
        $fcc = ConvertFrom-AtFccLock -Lines (Get-FixtureAnswer -Name 'fcc.unlocked.txt' -Folder device)
        $fcc.Mode | Should -Be 0
        $fcc.State | Should -Be 0
        $fcc.EffectiveMode | Should -Be 0
        $fcc.Unlocked | Should -BeTrue
    }

    It 'reads the documented locked module: unlock at every power-on, not unlocked, locked' {
        $fcc = ConvertFrom-AtFccLock -Lines (Get-FixtureAnswer -Name 'fcc.locked.txt')
        $fcc.Mode | Should -Be 2
        $fcc.State | Should -Be 0
        $fcc.EffectiveMode | Should -Be 2
        $fcc.Unlocked | Should -BeFalse
    }

    It 'reads <Name>' -ForEach @(
        @{ Name = 'a one-value status, not the documented layout'; Lines = @('+GTFCCEFFSTATUS: 1'); Mode = $null; Effective = $null; Unlocked = $null }
        @{ Name = 'an unknown unlock status'; Lines = @('+GTFCCEFFSTATUS: 1,7'); Mode = $null; Effective = 1; Unlocked = $null }
        @{ Name = 'a mode written but not in effect yet'; Lines = @('+GTFCCLOCKMODE: 0', '+GTFCCLOCKSTATE: 0', '+GTFCCEFFSTATUS: 2,0'); Mode = 0; Effective = 2; Unlocked = $false }
        @{ Name = 'the mode alone'; Lines = @('+GTFCCLOCKMODE: 1'); Mode = 1; Effective = $null; Unlocked = $null }
    ) {
        $fcc = ConvertFrom-AtFccLock -Lines $Lines
        $fcc.Mode | Should -Be $Mode
        $fcc.EffectiveMode | Should -Be $Effective
        $fcc.Unlocked | Should -Be $Unlocked
    }

    It 'gives nothing without any of the three lines' {
        ConvertFrom-AtFccLock -Lines @('+CME ERROR: 100') | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-FccLock' {
    It '<Name>: <Diagnosis>' -ForEach @(
        @{ Name = 'locked, not registered'; Lines = @('+GTFCCLOCKMODE: 2', '+GTFCCLOCKSTATE: 0', '+GTFCCEFFSTATUS: 2,0'); Registered = $false; Diagnosis = 'Locked'; PowerUp = $true }
        @{ Name = 'locked in mode 1, not registered'; Lines = @('+GTFCCEFFSTATUS: 1,0'); Registered = $false; Diagnosis = 'Locked'; PowerUp = $false }
        # The values never stop a modem that registers, whatever they say.
        @{ Name = 'locked values, but registered'; Lines = @('+GTFCCEFFSTATUS: 2,0'); Registered = $true; Diagnosis = 'NotLocked'; PowerUp = $true }
        @{ Name = 'unlocked, not registered'; Lines = @('+GTFCCLOCKMODE: 0', '+GTFCCLOCKSTATE: 0', '+GTFCCEFFSTATUS: 0,1'); Registered = $false; Diagnosis = 'NotLocked'; PowerUp = $false }
        @{ Name = 'unlocked for this power-on, not registered'; Lines = @('+GTFCCEFFSTATUS: 2,1'); Registered = $false; Diagnosis = 'NotLocked'; PowerUp = $true }
        @{ Name = 'a one-value status, not registered'; Lines = @('+GTFCCEFFSTATUS: 0'); Registered = $false; Diagnosis = 'Unknown'; PowerUp = $false }
        @{ Name = 'unreadable, registered'; Lines = $null; Registered = $true; Diagnosis = 'NotLocked'; PowerUp = $false }
        @{ Name = 'unreadable, not registered'; Lines = $null; Registered = $false; Diagnosis = 'Unknown'; PowerUp = $false }
    ) {
        $fcc = if ($Lines) { ConvertFrom-AtFccLock -Lines $Lines }
        $result = Resolve-FccLock -Fcc $fcc -Registered:$Registered
        $result.Diagnosis | Should -Be $Diagnosis
        $result.PowerUpUnlock | Should -Be $PowerUp
    }
}

Describe 'Invoke-FccUnlock' {
    BeforeEach {
        $script:modem = Get-LockedModem
        $script:channel = New-AtChannel -Transport $script:modem
        [void](Initialize-AtChannel -Channel $script:channel)
    }

    AfterEach {
        Close-AtChannel -Channel $script:channel
    }

    It 'reads the lock, runs the known sequence once, and restarts the modem' {
        $result = Invoke-FccUnlock -Channel $script:channel -Confirm:$false
        $result.Result | Should -Be 'Restarted'
        Get-SentCommand -Modem $script:modem | Should -Be (@($script:readCommand) + $script:unlockCommands)
        $result.Steps.Command | Should -Be (@($script:readCommand) + $script:unlockCommands)
    }

    It 'goes on past the read-only status command''s documented ERROR' {
        $result = Invoke-FccUnlock -Channel $script:channel -Confirm:$false
        ($result.Steps | Where-Object Command -EQ 'AT+GTFCCEFFSTATUS=0,0').Status | Should -Be 'Error'
        $result.Result | Should -Be 'Restarted'
    }

    It 'reads the lock lifted once the modem is back' {
        [void](Invoke-FccUnlock -Channel $script:channel -Confirm:$false)
        Start-Sleep -Milliseconds 50
        [void](Receive-AtUrc -Channel $script:channel -TimeoutMs 10)
        $script:modem.Lost | Should -BeTrue
        $script:modem.Reappear('COM9')
        $script:modem.SetAnswer($script:readCommand, @('+GTFCCLOCKMODE: 0', '+GTFCCLOCKSTATE: 0', '+GTFCCEFFSTATUS: 0,1', 'OK'))
        $again = New-AtChannel -Transport $script:modem
        try {
            [void](Initialize-AtChannel -Channel $again)
            $read = Invoke-AtCommand -Channel $again -Command $script:readCommand
            (Resolve-FccLock -Fcc (ConvertFrom-AtFccLock -Lines $read.Lines)).Diagnosis | Should -Be 'NotLocked'
        }
        finally {
            Close-AtChannel -Channel $again
        }
    }

    It 'stops at the first command that fails, without restarting: <Failing>' -ForEach @(
        @{ Failing = 'AT+GTFCCLOCKMODE=0' }
        @{ Failing = 'AT+GTFCCLOCKSTATE=0' }
        @{ Failing = 'AT&W' }
    ) {
        $script:modem.SetAnswer($Failing, @('+CME ERROR: 3'))
        $result = Invoke-FccUnlock -Channel $script:channel -Confirm:$false
        $result.Result | Should -Be 'Failed'
        $sent = Get-SentCommand -Modem $script:modem
        $sent[-1] | Should -Be $Failing
        $sent | Should -Not -Contain 'AT+CFUN=1,1'
    }

    It 'counts a restart whose OK never comes as done' {
        $script:modem.Script('AT+CFUN=1,1', @{ NoFinal = $true; Lines = @('OK') })
        (Invoke-FccUnlock -Channel $script:channel -Confirm:$false).Result | Should -Be 'Restarted'
    }

    It 'writes nothing to a module that says it is unlocked' {
        $script:modem.SetAnswer($script:readCommand, @('+GTFCCLOCKMODE: 0', '+GTFCCLOCKSTATE: 0', '+GTFCCEFFSTATUS: 0,1', 'OK'))
        (Invoke-FccUnlock -Channel $script:channel -Confirm:$false).Result | Should -Be 'NotLocked'
        Get-SentCommand -Modem $script:modem | Should -Be @($script:readCommand)
    }

    It 'writes nothing when the lock can''t be read: <Answer>' -ForEach @(
        @{ Answer = @('ERROR') }
        @{ Answer = @('+GTFCCEFFSTATUS: 0', 'OK') }
    ) {
        $script:modem.SetAnswer($script:readCommand, $Answer)
        (Invoke-FccUnlock -Channel $script:channel -Confirm:$false).Result | Should -Be 'Unknown'
        Get-SentCommand -Modem $script:modem | Should -Be @($script:readCommand)
    }

    It 'writes nothing without a confirmation' {
        (Invoke-FccUnlock -Channel $script:channel -WhatIf).Result | Should -Be 'Declined'
        Get-SentCommand -Modem $script:modem | Should -Be @($script:readCommand)
    }

    It 'reports a port lost before the restart' {
        $script:modem.Script('AT+GTFCCLOCKSTATE=0', @{ Vanish = $true; Lines = @(); NoFinal = $true })
        (Invoke-FccUnlock -Channel $script:channel -Confirm:$false).Result | Should -Be 'PortLost'
        Get-SentCommand -Modem $script:modem | Should -Not -Contain 'AT&W'
    }
}
