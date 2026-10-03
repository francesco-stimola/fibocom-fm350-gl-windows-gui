# Starting the app at sign-in: the installer's logon task read and turned on or off - Task
# Scheduler's cmdlets mocked, no task touched -; the worker's command on the simulated device, as
# installed and not; what the window shows, and its Save turning it on only when changed.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force

    function Invoke-Click {
        param([object] $Button)
        $Button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'The logon task' {
    It 'reads <State> as <Expected>' -ForEach @(
        @{ State = 'Ready'; Expected = $true }
        @{ State = 'Running'; Expected = $true }
        @{ State = 'Disabled'; Expected = $false }
    ) {
        Mock -ModuleName FibocomFm350 Get-ScheduledTask { [pscustomobject]@{ State = $State } }
        Get-AppLogonTask | Should -Be $Expected
        Should -Invoke -ModuleName FibocomFm350 Get-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\fibocom-fm350-gl-windows-gui\' -and $TaskName -eq 'Start at logon' }
    }

    It 'reads nothing when the app is not installed' {
        Mock -ModuleName FibocomFm350 Get-ScheduledTask { }
        Get-AppLogonTask | Should -BeNullOrEmpty
    }

    It 'turns it on and off, and never creates one' {
        Mock -ModuleName FibocomFm350 Enable-ScheduledTask { }
        Mock -ModuleName FibocomFm350 Disable-ScheduledTask { }
        Set-AppLogonTask -Enabled $true -Confirm:$false
        Should -Invoke -ModuleName FibocomFm350 Enable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Start at logon' }
        Set-AppLogonTask -Enabled $false -Confirm:$false
        Should -Invoke -ModuleName FibocomFm350 Disable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Start at logon' }
        Set-AppLogonTask -Enabled $true -WhatIf
        Should -Invoke -ModuleName FibocomFm350 Enable-ScheduledTask -Times 1 -Exactly -Because '-WhatIf changes nothing'
    }
}

Describe 'The worker and the start at sign-in' {
    BeforeEach {
        $script:link = New-ModemWorkerLink
        $script:device = New-SimulatedDevice -Scenario Online
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid())
    }

    AfterEach {
        Close-ModemWorker -Worker $script:worker
        Close-ModemWorkerLink -Link $script:link
    }

    It 'says the app is not installed in development mode, and changes nothing' {
        $script:worker = New-ModemWorker -Link $script:link -Simulation $script:device -DataFolder $script:folder
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].StartAtLogon | Should -BeNullOrEmpty
        [void](Send-ModemCommand -Link $script:link -Kind SetStartAtLogon -Parameter @{ Enabled = $true })
        Invoke-ModemWorkerCycle -Worker $script:worker
        @($script:link['Snapshot'].Results)[-1].Result | Should -Be 'NoTask'
        $script:device.LogonTask | Should -BeNullOrEmpty
        (ConvertTo-WindowView -Snapshot $script:link['Snapshot']).Result | Should -Match 'Only the installed app can start when you sign in to Windows'
    }

    It 'turns it on and off as installed, and says so' {
        $script:device.LogonTask = $false
        $script:worker = New-ModemWorker -Link $script:link -Simulation $script:device -DataFolder $script:folder
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:link['Snapshot'].StartAtLogon | Should -BeFalse
        [void](Send-ModemCommand -Link $script:link -Kind SetStartAtLogon -Parameter @{ Enabled = $true })
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.LogonTask | Should -BeTrue
        $snapshot = $script:link['Snapshot']
        $snapshot.StartAtLogon | Should -BeTrue
        @($snapshot.Results)[-1].Result | Should -Be 'Enabled'
        (ConvertTo-WindowView -Snapshot $snapshot).Result | Should -Match 'The app now starts when you sign in to Windows\.'
        [void](Send-ModemCommand -Link $script:link -Kind SetStartAtLogon -Parameter @{ Enabled = $false })
        Invoke-ModemWorkerCycle -Worker $script:worker
        $script:device.LogonTask | Should -BeFalse
        $script:link['Snapshot'].StartAtLogon | Should -BeFalse
    }

    It 'changes nothing while it only observes' {
        $script:device.LogonTask = $false
        $script:worker = New-ModemWorker -Link $script:link -Simulation $script:device -DataFolder $script:folder -ObserveOnly
        Invoke-ModemWorkerCycle -Worker $script:worker
        [void](Send-ModemCommand -Link $script:link -Kind SetStartAtLogon -Parameter @{ Enabled = $true })
        Invoke-ModemWorkerCycle -Worker $script:worker
        @($script:link['Snapshot'].Results)[-1].Result | Should -Be 'Refused'
        $script:device.LogonTask | Should -BeFalse
    }

    It 'reads the installed app''s task when there is no simulated device, and says nothing on a failed read' {
        Mock -ModuleName FibocomFm350 Get-AppLogonTask { throw 'Task Scheduler is not answering.' }
        $script:worker = New-ModemWorker -Link $script:link -DataFolder $script:folder
        & (Get-Module FibocomFm350) { param($w) Update-WorkerStartAtLogon -Worker $w } $script:worker
        $script:worker.StartAtLogon | Should -BeNullOrEmpty
        Mock -ModuleName FibocomFm350 Get-AppLogonTask { $true }
        & (Get-Module FibocomFm350) { param($w) Update-WorkerStartAtLogon -Worker $w } $script:worker
        $script:worker.StartAtLogon | Should -BeTrue
    }
}

Describe 'What the window shows of it' {
    It '<Name>' -ForEach @(
        @{ Name = 'nothing before a snapshot'; Snapshot = $null; Worker = 'Running'; Checked = $false; CanChange = $false; Note = $null }
        @{ Name = 'on, and changeable, as installed'; Snapshot = @{ StartAtLogon = $true; ObserveOnly = $false; Elevated = $true }; Worker = 'Running'; Checked = $true; CanChange = $true; Note = $null }
        @{ Name = 'off, and changeable'; Snapshot = @{ StartAtLogon = $false; ObserveOnly = $false; Elevated = $true }; Worker = 'Running'; Checked = $false; CanChange = $true; Note = $null }
        @{ Name = 'not installed'; Snapshot = @{ StartAtLogon = $null; ObserveOnly = $false; Elevated = $true }; Worker = 'Running'; Checked = $false; CanChange = $false; Note = 'Only the installed app can start when you sign in to Windows.' }
        @{ Name = 'observing only'; Snapshot = @{ StartAtLogon = $false; ObserveOnly = $true; Elevated = $true }; Worker = 'Running'; Checked = $false; CanChange = $false; Note = 'The app only observes: it changes nothing.' }
        @{ Name = 'without administrator rights'; Snapshot = @{ StartAtLogon = $true; ObserveOnly = $false; Elevated = $false }; Worker = 'Running'; Checked = $true; CanChange = $false; Note = 'Changing it needs administrator rights.' }
        @{ Name = 'a worker restarting'; Snapshot = @{ StartAtLogon = $false; ObserveOnly = $false; Elevated = $true }; Worker = 'Restarting'; Checked = $false; CanChange = $false; Note = $null }
    ) {
        $snapshot = if ($Snapshot) { [pscustomobject]$Snapshot } else { $null }
        $view = & (Get-Module FibocomFm350.App) { param($s, $w) Get-StartupView -Snapshot $s -Worker $w } $snapshot $Worker
        $view.Checked | Should -Be $Checked
        $view.CanChange | Should -Be $CanChange
        $view.Note | Should -Be $Note
    }
}

Describe 'The window''s start at sign-in' {
    BeforeAll {
        # The Online scenario's view, as an installed app with the logon task off, and as the app
        # in development mode.
        function Get-StartupScenarioView {
            param([object] $LogonTask)
            $link = New-ModemWorkerLink
            $device = New-SimulatedDevice -Scenario Online
            $device.LogonTask = $LogonTask
            $worker = New-ModemWorker -Link $link -Simulation $device -DataFolder (Join-Path $TestDrive ([guid]::NewGuid()))
            try {
                Invoke-ModemWorkerCycle -Worker $worker
                ConvertTo-WindowView -Snapshot $link['Snapshot']
            }
            finally {
                Close-ModemWorker -Worker $worker
                Close-ModemWorkerLink -Link $link
            }
        }
        $script:installed = Get-StartupScenarioView -LogonTask $false
        $script:notInstalled = Get-StartupScenarioView -LogonTask $null
    }

    BeforeEach {
        $script:sent = [System.Collections.Generic.List[object]]::new()
        $script:window = New-MainWindow -Send { param($kind, $parameter) $script:sent.Add([pscustomobject]@{ Kind = $kind; Parameter = $parameter }) }
        $script:controls = $script:window.Controls
    }

    AfterEach {
        $script:window.Exiting = $true
        $script:window.Window.Close()
    }

    It 'shows the logon task''s state, and turns it on at Save only when changed' {
        Update-MainWindow -View $script:installed
        $script:controls.StartupBox.IsChecked | Should -BeFalse
        $script:controls.StartupBox.IsEnabled | Should -BeTrue
        Invoke-Click $script:controls.SaveSettingsButton
        @($script:sent | Where-Object Kind -EQ 'SetStartAtLogon').Count | Should -Be 0 -Because 'nothing changed'
        $script:controls.StartupBox.IsChecked = $true
        Invoke-Click $script:controls.SaveSettingsButton
        $command = @($script:sent | Where-Object Kind -EQ 'SetStartAtLogon')
        $command.Count | Should -Be 1
        $command[0].Parameter.Enabled | Should -BeTrue
    }

    It 'greys it out, and says why, for an app not installed' {
        Update-MainWindow -View $script:notInstalled
        $script:controls.StartupBox.IsEnabled | Should -BeFalse
        $script:controls.StartupNoteText.Visibility | Should -Be 'Visible'
        $script:controls.StartupNoteText.Text | Should -Match 'Only the installed app'
        $script:controls.StartupBox.IsChecked = $true
        Invoke-Click $script:controls.SaveSettingsButton
        @($script:sent | Where-Object Kind -EQ 'SetStartAtLogon').Count | Should -Be 0
    }
}
