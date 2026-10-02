# The recovery ladder: the decision as a matrix - symptoms and history in, step out - written
# against the module's own timings, so that it holds whatever values are decided; maintenance
# windows; and each step on the simulated modem and device, or with the system calls mocked.

BeforeDiscovery {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    $script:t = & (Get-Module FibocomFm350) { $script:RecoveryTimings }
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    $script:t = & (Get-Module FibocomFm350) { $script:RecoveryTimings }

    # A recovery history with the given values; everything else as at the start.
    function Get-TestHistory {
        param([hashtable] $Value = @{})
        $history = [ordered]@{
            Check = $null; FailingSince = $null; HealthySince = $null; Step = $null; StepAt = $null
            Cycles = 0; CycleEndedAt = $null; MaintenanceUntil = $null; MaintenanceBroken = $false
        }
        foreach ($key in $Value.Keys) { $history[$key] = $Value[$key] }
        [pscustomobject]$history
    }

    # One decision; -Check left out when healthy.
    function Get-TestDecision {
        param([long] $Now, [string] $Check, [hashtable] $History = @{}, [switch] $Blocked, [switch] $NotElevated, [switch] $Withhold, [switch] $Resumed, [switch] $Unknown, [switch] $NoReset)
        $options = @{ Now = $Now; History = (Get-TestHistory -Value $History); Elevated = -not $NotElevated; Blocked = $Blocked; Withhold = $Withhold; Resumed = $Resumed; Unknown = $Unknown; NoReset = $NoReset }
        if ($Check) { $options['Check'] = $Check }
        Resolve-RecoveryAction @options
    }
}

AfterAll {
    Remove-Module FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'Resolve-RecoveryAction' {
    Context 'the entry step: the symptom picks it, once its grace time is over' {
        It '<Check> -> <Step>' -ForEach @(
            @{ Check = 'H2'; Step = 'R6' }
            @{ Check = 'H3'; Step = 'R5' }
            @{ Check = 'H4'; Step = 'R3' }
            @{ Check = 'H5'; Step = 'R2' }
            @{ Check = 'H6'; Step = 'R1' }
            @{ Check = 'H7'; Step = 'R2' }
        ) {
            $grace = $script:t.Grace[$Check]
            if ($grace -gt 0) {
                $early = Get-TestDecision -Now 1000 -Check $Check
                $early.Action | Should -Be 'None'
                $early.Status | Should -Be 'Watching'
                $early.WaitMs | Should -Be $grace
                $early.History.FailingSince | Should -Be 1000
            }
            $due = Get-TestDecision -Now (1000 + $grace) -Check $Check -History @{ Check = $Check; FailingSince = 1000 }
            $due.Action | Should -Be $Step
            $due.Status | Should -Be 'Recovering'
            $due.History.Step | Should -Be $Step
            $due.History.StepAt | Should -Be (1000 + $grace)
            $due.WaitMs | Should -Be $script:t.Settle[$Step]
        }

        It 'H1 - no modem on USB - has no step: nothing reaches a device that is gone' {
            $decision = Get-TestDecision -Now 10000000 -Check 'H1' -History @{ FailingSince = 0 }
            $decision.Action | Should -Be 'None'
            $decision.Status | Should -Be 'Watching'
            $decision.WaitMs | Should -BeNullOrEmpty
        }
    }

    Context 'what no reset fixes is never escalated' {
        It '<Check> blocked, however long it lasts: no step' -ForEach @(
            @{ Check = 'H1' }, @{ Check = 'H2' }, @{ Check = 'H3' }, @{ Check = 'H4' }, @{ Check = 'H5' }, @{ Check = 'H6' }
        ) {
            $decision = Get-TestDecision -Now 100000000 -Check $Check -Blocked -History @{ FailingSince = 0 }
            $decision.Action | Should -Be 'None'
            $decision.Status | Should -Be 'Blocked'
            $decision.WaitMs | Should -BeNullOrEmpty
            $decision.History.FailingSince | Should -BeNullOrEmpty -Because 'once unblocked, the check gets its grace time'
        }

        It 'never escalates a state that couldn''t be read: <Check>' -ForEach @(
            @{ Check = 'H3' }, @{ Check = 'H5' }
        ) {
            $decision = Get-TestDecision -Now 100000000 -Check $Check -Unknown -History @{ Check = $Check; FailingSince = 0 }
            $decision.Action | Should -Be 'None'
            $decision.Status | Should -Be 'Watching'
            $decision.WaitMs | Should -BeNullOrEmpty
            $decision.History.FailingSince | Should -BeNullOrEmpty -Because 'once readable and failing, the check gets its grace time'
        }

        It 'unblocked, the check gets its grace time from then' {
            $blocked = Get-TestDecision -Now 500000 -Check 'H4' -Blocked
            $after = Resolve-RecoveryAction -Now 600000 -Check 'H4' -History $blocked.History -Elevated
            $after.Status | Should -Be 'Watching'
            $after.WaitMs | Should -Be $script:t.Grace['H4']
        }
    }

    Context 'climbing the ladder' {
        It 'gives a step its settle time, whatever fails meanwhile - <Check>' -ForEach @(
            @{ Check = 'H7'; Blocked = $false }
            @{ Check = 'H1'; Blocked = $true }
        ) {
            $decision = Get-TestDecision -Now 20000 -Check $Check -Blocked:$Blocked -History @{ FailingSince = 0; Step = 'R5'; StepAt = 10000 }
            $decision.Action | Should -Be 'None'
            $decision.Status | Should -Be 'Settling'
            $decision.Step | Should -Be 'R5'
            $decision.WaitMs | Should -Be ($script:t.Settle['R5'] - 10000)
        }

        It 'after <Last>, with <Check> failing: <Next>' -ForEach @(
            @{ Last = 'R1'; Check = 'H6'; Next = 'R2' }
            @{ Last = 'R2'; Check = 'H7'; Next = 'R3' }
            @{ Last = 'R3'; Check = 'H7'; Next = 'R4' }
            @{ Last = 'R4'; Check = 'H7'; Next = 'R5' }
            @{ Last = 'R2'; Check = 'H4'; Next = 'R3' }
            @{ Last = 'R3'; Check = 'H4'; Next = 'R4' }
            @{ Last = 'R4'; Check = 'H5'; Next = 'R5' }
            @{ Last = 'R5'; Check = 'H2'; Next = 'R6' }
            @{ Last = 'R2'; Check = 'H2'; Next = 'R6' }
            @{ Last = 'R1'; Check = 'H4'; Next = 'R3' }
        ) {
            $at = 1000000
            $decision = Get-TestDecision -Now ($at + $script:t.Settle[$Last]) -Check $Check -History @{ Check = $Check; FailingSince = 0; Step = $Last; StepAt = $at }
            $decision.Action | Should -Be $Next
            $decision.History.Step | Should -Be $Next
            $decision.History.Cycles | Should -Be 0
        }

        It 'after <Last>, with <Check> failing: the cycle is over, the next after the backoff' -ForEach @(
            @{ Last = 'R5'; Check = 'H7' }
            @{ Last = 'R5'; Check = 'H4' }
            @{ Last = 'R6'; Check = 'H2' }
            @{ Last = 'R6'; Check = 'H5' }
            @{ Last = 'R5'; Check = 'H3' }
        ) {
            $now = 1000000 + $script:t.Settle[$Last]
            $decision = Get-TestDecision -Now $now -Check $Check -History @{ Check = $Check; FailingSince = 0; Step = $Last; StepAt = 1000000 }
            $decision.Action | Should -Be 'None'
            $decision.Status | Should -Be 'Waiting'
            $decision.Cycles | Should -Be 1
            $decision.History.Step | Should -BeNullOrEmpty
            $decision.History.CycleEndedAt | Should -Be $now
            $decision.WaitMs | Should -Be $script:t.Backoff[0]
        }

        It 'gives a check that starts failing on the way its own grace time: past R3''s settle, H4 becomes H2' {
            $history = @{ Check = 'H4'; FailingSince = 0; Step = 'R3'; StepAt = 120000 }
            $now = 120000 + $script:t.Settle['R3'] + 1000
            $silent = Get-TestDecision -Now $now -Check 'H2' -History $history
            $silent.Action | Should -Be 'None'
            $silent.Status | Should -Be 'Watching'
            $silent.WaitMs | Should -Be $script:t.Grace['H2']
            $still = Resolve-RecoveryAction -Now ($now + $script:t.Grace['H2']) -Check 'H2' -History $silent.History -Elevated
            $still.Action | Should -Be 'R6'
        }

        It 'counts a check that changed during a step''s settle time from the end of it' {
            $settling = Get-TestDecision -Now 200000 -Check 'H1' -History @{ Check = 'H7'; FailingSince = 0; Step = 'R5'; StepAt = 100000 }
            $settling.Status | Should -Be 'Settling'
            $after = Resolve-RecoveryAction -Now (100000 + $script:t.Settle['R5']) -Check 'H2' -History $settling.History -Elevated
            $after.Status | Should -Be 'Watching'
            $after.WaitMs | Should -Be $script:t.Grace['H2']
        }

        It 'skips the reset when the SIM would then wait for a PIN the app doesn''t have' {
            $after = Get-TestDecision -Now 10000000 -Check 'H7' -History @{ Check = 'H7'; FailingSince = 0; Step = 'R4'; StepAt = 0 } -NoReset
            $after.Action | Should -Be 'None'
            $after.Status | Should -Be 'Waiting'
            $after.Cycles | Should -Be 1
            $sim = Get-TestDecision -Now 10000000 -Check 'H3' -History @{ Check = 'H3'; FailingSince = 0 } -NoReset
            $sim.Action | Should -Be 'None'
            $sim.Status | Should -Be 'Watching'
            (Get-TestDecision -Now 10000000 -Check 'H7' -History @{ Check = 'H7'; FailingSince = 0; Step = 'R4'; StepAt = 0 }).Action | Should -Be 'R5'
        }

        It 'skips the steps that need administrator rights without them' {
            (Get-TestDecision -Now 100000000 -Check 'H6' -History @{ Check = 'H6'; FailingSince = 0 } -NotElevated).Action | Should -Be 'R2'
            $silent = Get-TestDecision -Now 100000000 -Check 'H2' -History @{ Check = 'H2'; FailingSince = 0 } -NotElevated
            $silent.Action | Should -Be 'None'
            $silent.Status | Should -Be 'Watching'
        }
    }

    Context 'cycles, backoff and the slow cadence' {
        It 'after <Cycles> failed cycle(s): <Status> for the backoff, then the entry step again' -ForEach @(
            @{ Cycles = 1; Status = 'Waiting' }
            @{ Cycles = 2; Status = 'Waiting' }
            @{ Cycles = 3; Status = 'SlowCadence' }
            @{ Cycles = 7; Status = 'SlowCadence' }
        ) {
            $backoff = $script:t.Backoff[[Math]::Min($Cycles, $script:t.Backoff.Count) - 1]
            $expected = if ($Cycles -ge $script:t.Backoff.Count) { 'SlowCadence' } else { 'Waiting' }
            $Status | Should -Be $expected -Because 'the case names the status the timings give'
            $history = @{ FailingSince = 0; Cycles = $Cycles; CycleEndedAt = 1000000 }
            $waiting = Get-TestDecision -Now 1000001 -Check 'H7' -History $history
            $waiting.Status | Should -Be $Status
            $waiting.WaitMs | Should -Be ($backoff - 1)
            $again = Get-TestDecision -Now (1000000 + $backoff) -Check 'H7' -History $history
            $again.Action | Should -Be 'R2'
            $again.Cycles | Should -Be $Cycles
        }

        It 'starts the ladder and the cycles over once health has held long enough' {
            $history = @{ Step = 'R3'; StepAt = 0; Cycles = 2; CycleEndedAt = 0; HealthySince = 1000000 }
            $early = Get-TestDecision -Now (1000000 + $script:t.StableMs - 1) -History $history
            $early.Status | Should -Be 'Healthy'
            $early.History.Step | Should -Be 'R3'
            $early.Cycles | Should -Be 2
            $early.WaitMs | Should -Be 1
            $stable = Get-TestDecision -Now (1000000 + $script:t.StableMs) -History $history
            $stable.History.Step | Should -BeNullOrEmpty
            $stable.Cycles | Should -Be 0
            $stable.WaitMs | Should -BeNullOrEmpty
        }

        It 'carries on up the ladder when the symptom comes back before health has held' {
            # R2 mended it for a while; it fails again: the next step, not R2 once more.
            $healthy = Get-TestDecision -Now 2000000 -History @{ FailingSince = 0; Step = 'R2'; StepAt = 1000000 }
            $healthy.Status | Should -Be 'Healthy'
            $again = Resolve-RecoveryAction -Now 2100000 -Check 'H7' -History $healthy.History -Elevated
            $again.Action | Should -Be 'R3'
        }

        It 'gives a symptom that comes back its grace time before the next step' {
            $healthy = Get-TestDecision -Now 2000000 -History @{ FailingSince = 0; Step = 'R3'; StepAt = 1000000 }
            $again = Resolve-RecoveryAction -Now 2100000 -Check 'H4' -History $healthy.History -Elevated
            $again.Status | Should -Be 'Watching'
            $later = Resolve-RecoveryAction -Now (2100000 + $script:t.Grace['H4']) -Check 'H4' -History $again.History -Elevated
            $later.Action | Should -Be 'R4'
        }
    }

    Context 'healthy' {
        It 'with nothing done: no step, nothing to wait for' {
            $decision = Get-TestDecision -Now 1000
            $decision.Action | Should -Be 'None'
            $decision.Status | Should -Be 'Healthy'
            $decision.WaitMs | Should -BeNullOrEmpty
            $decision.History.HealthySince | Should -Be 1000
        }

        It 'ends a step''s settle time at once, and a maintenance window once the link came back' {
            $decision = Get-TestDecision -Now 1000 -History @{ Step = 'R5'; StepAt = 500; MaintenanceUntil = 900000; MaintenanceBroken = $true; FailingSince = 0 }
            $decision.Status | Should -Be 'Healthy'
            $decision.History.MaintenanceUntil | Should -BeNullOrEmpty
            $decision.History.FailingSince | Should -BeNullOrEmpty
        }

        It 'keeps a maintenance window open while the operation hasn''t broken the link yet' {
            $opened = Open-MaintenanceWindow -Now 1000 -DurationMs 100000
            $before = Resolve-RecoveryAction -Now 2000 -History $opened -Elevated
            $before.Status | Should -Be 'Healthy'
            $before.History.MaintenanceUntil | Should -Be 101000
            $broken = Resolve-RecoveryAction -Now 3000 -Check 'H4' -History $before.History -Elevated
            $broken.Status | Should -Be 'Maintenance'
            $back = Resolve-RecoveryAction -Now 4000 -History $broken.History -Elevated
            $back.History.MaintenanceUntil | Should -BeNullOrEmpty
            $again = Resolve-RecoveryAction -Now 5000 -Check 'H4' -History $back.History -Elevated
            $again.Status | Should -Be 'Watching'
        }
    }

    Context 'maintenance windows, the observe-only mode, a pause' {
        It 'suspends escalation while a window is open, and gives the grace time from its end' {
            $open = Get-TestDecision -Now 1000 -Check 'H4' -History @{ MaintenanceUntil = 100000; FailingSince = 0 }
            $open.Status | Should -Be 'Maintenance'
            $open.Action | Should -Be 'None'
            $open.WaitMs | Should -Be 99000
            $over = Resolve-RecoveryAction -Now 100000 -Check 'H4' -History $open.History -Elevated
            $over.Status | Should -Be 'Watching'
            $over.History.MaintenanceUntil | Should -BeNullOrEmpty
            $over.WaitMs | Should -Be $script:t.Grace['H4']
        }

        It 'names the step it withholds, and remembers none' {
            $decision = Get-TestDecision -Now 100000000 -Check 'H7' -History @{ FailingSince = 0 } -Withhold
            $decision.Action | Should -Be 'R2'
            $decision.Status | Should -Be 'Withheld'
            $decision.Step | Should -Be 'R2'
            $decision.History.Step | Should -BeNullOrEmpty
            $again = Resolve-RecoveryAction -Now 200000000 -Check 'H7' -History $decision.History -Elevated -Withhold
            $again.Action | Should -Be 'R2'
        }

        It 'gives a failing check its grace time again after a pause' {
            $decision = Get-TestDecision -Now 100000000 -Check 'H4' -History @{ FailingSince = 0 } -Resumed
            $decision.Status | Should -Be 'Watching'
            $decision.History.FailingSince | Should -Be 100000000
        }
    }

    It 'returns a new history and leaves the one it was given as it was' {
        $history = Get-TestHistory -Value @{ FailingSince = 0 }
        $before = $history | ConvertTo-Json
        $decision = Resolve-RecoveryAction -Now 100000000 -Check 'H7' -History $history -Elevated
        $decision.History.Step | Should -Be 'R2'
        $history | ConvertTo-Json | Should -Be $before
    }
}

Describe 'Open-MaintenanceWindow' {
    It 'opens a window of the given length, or the default' {
        (Open-MaintenanceWindow -Now 1000 -DurationMs 5000).MaintenanceUntil | Should -Be 6000
        (Open-MaintenanceWindow -Now 1000).MaintenanceUntil | Should -Be (1000 + $script:t.Maintenance)
    }

    It 'never shortens a window already open, and keeps the rest of the history' {
        $history = Get-TestHistory -Value @{ MaintenanceUntil = 900000; Step = 'R2'; Cycles = 1 }
        $opened = Open-MaintenanceWindow -History $history -Now 1000 -DurationMs 5000
        $opened.MaintenanceUntil | Should -Be 900000
        $opened.Step | Should -Be 'R2'
        $opened.Cycles | Should -Be 1
        $history.MaintenanceUntil | Should -Be 900000
    }
}

Describe 'Invoke-RecoveryStep' {
    Context 'on the simulated modem' {
        BeforeEach {
            $script:device = New-SimulatedDevice -Scenario Online
            $script:channel = New-AtChannel -Transport $script:device.Open()
        }

        AfterEach {
            Close-AtChannel -Channel $script:channel
        }

        It '<Step> sends <Command>' -ForEach @(
            @{ Step = 'R2'; Command = 'AT+CGACT=0,1' }
            @{ Step = 'R3'; Command = 'AT+COPS=2' }
            @{ Step = 'R4'; Command = 'AT+CFUN=4' }
            @{ Step = 'R5'; Command = 'AT+CFUN=15' }
        ) {
            $outcome = Invoke-RecoveryStep -Step $Step -Channel $script:channel -Confirm:$false
            $outcome.Result | Should -Be 'Done'
            $outcome.Commands[0].Command | Should -Be $Command
            $script:device.Modem.Received | Should -Contain $Command
        }

        It 'counts a reset whose OK never comes as done: the modem is restarting' {
            $script:device.Modem.Script('AT+CFUN=15', @{ NoFinal = $true })
            (Invoke-RecoveryStep -Step R5 -Channel $script:channel -Confirm:$false).Result | Should -Be 'Done'
        }

        It 'says a step the modem refused failed' {
            $script:device.Modem.SetAnswer('AT+CGACT=0,1', @('+CME ERROR: 148'))
            $outcome = Invoke-RecoveryStep -Step R2 -Channel $script:channel -Confirm:$false
            $outcome.Result | Should -Be 'Failed'
            $outcome.Commands[0].ErrorCode | Should -Be 148
        }

        It 'sends nothing without an open channel' {
            Close-AtChannel -Channel $script:channel
            (Invoke-RecoveryStep -Step R3 -Channel $script:channel -Confirm:$false).Result | Should -Be 'NoModem'
            (Invoke-RecoveryStep -Step R3 -Confirm:$false).Result | Should -Be 'NoModem'
        }

        It 'sends nothing with -WhatIf' {
            (Invoke-RecoveryStep -Step R4 -Channel $script:channel -WhatIf).Result | Should -Be 'Declined'
            $script:device.Modem.Received | Should -Not -Contain 'AT+CFUN=4'
        }

        It 'R1 removes the adapter''s route, then its address, for the next pass to set them again' {
            $outcome = Invoke-RecoveryStep -Step R1 -Simulation $script:device -Confirm:$false
            $outcome.Result | Should -Be 'Done'
            $outcome.Commands.Command | Should -Be @('RemoveGateway', 'RemoveAddress')
            $adapter = $script:device.Adapter.Read()
            $adapter.Gateways | Should -BeNullOrEmpty
            $adapter.Addresses | Should -BeNullOrEmpty
        }

        It 'R6 restarts the simulated USB device: the modem leaves USB' {
            $script:device.AwayMs = 60000
            (Invoke-RecoveryStep -Step R6 -Simulation $script:device -Confirm:$false).Result | Should -Be 'Done'
            $script:device.Find().Device | Should -Be 'Absent'
        }
    }

    Context 'on the system, mocked' {
        BeforeEach {
            $script:adapter = (New-SimulatedDevice -Scenario Online).Adapter.Read()
            Mock -ModuleName FibocomFm350 Get-ModemAdapterState { $script:adapter }
            Mock -ModuleName FibocomFm350 Set-ModemAdapterConfiguration { foreach ($action in $Plan.Actions) { [pscustomobject]@{ Action = $action.Action; Done = $true; Error = $null } } }
            Mock -ModuleName FibocomFm350 Restart-ModemUsbDevice { [pscustomobject]@{ Done = $true; ExitCode = 0 } }
        }

        It 'R1 clears the adapter it finds by its instance ID' {
            $outcome = Invoke-RecoveryStep -Step R1 -AdapterInstanceId 'USB\VID_0E8D&PID_7127&MI_00\X' -Confirm:$false
            $outcome.Result | Should -Be 'Done'
            Should -Invoke -ModuleName FibocomFm350 Get-ModemAdapterState -Times 1 -Exactly -ParameterFilter { $InstanceId -eq 'USB\VID_0E8D&PID_7127&MI_00\X' }
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 1 -Exactly -ParameterFilter {
                $InterfaceIndex -eq 99 -and ($Plan.Actions.Action -join ',') -eq 'RemoveGateway,RemoveAddress'
            }
        }

        It 'R1 does nothing without the adapter' {
            Mock -ModuleName FibocomFm350 Get-ModemAdapterState { }
            (Invoke-RecoveryStep -Step R1 -AdapterInstanceId 'USB\VID_0E8D&PID_7127&MI_00\X' -Confirm:$false).Result | Should -Be 'NoModem'
            Should -Invoke -ModuleName FibocomFm350 Set-ModemAdapterConfiguration -Times 0 -Exactly
        }

        It 'R6 restarts the USB device it is given; a restart Windows postpones failed' {
            (Invoke-RecoveryStep -Step R6 -DeviceInstanceId 'USB\VID_0E8D&PID_7127\5&1&0&3' -Confirm:$false).Result | Should -Be 'Done'
            Should -Invoke -ModuleName FibocomFm350 Restart-ModemUsbDevice -Times 1 -Exactly -ParameterFilter { $InstanceId -eq 'USB\VID_0E8D&PID_7127\5&1&0&3' }
            Mock -ModuleName FibocomFm350 Restart-ModemUsbDevice { [pscustomobject]@{ Done = $false; ExitCode = 3010 } }
            $outcome = Invoke-RecoveryStep -Step R6 -DeviceInstanceId 'USB\VID_0E8D&PID_7127\5&1&0&3' -Confirm:$false
            $outcome.Result | Should -Be 'Failed'
            $outcome.Commands[0].Status | Should -Be 'Exit 3010'
        }

        It 'R6 does nothing without a device' {
            (Invoke-RecoveryStep -Step R6 -Confirm:$false).Result | Should -Be 'NoModem'
            Should -Invoke -ModuleName FibocomFm350 Restart-ModemUsbDevice -Times 0 -Exactly
        }
    }
}
