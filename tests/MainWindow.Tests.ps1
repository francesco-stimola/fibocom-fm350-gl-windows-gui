# The main window, never shown: it loads, takes the view of every simulated scenario, and turns
# its buttons into commands for the worker - the two that change something outside the app only
# after a confirmation.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force

    function Get-ScenarioView {
        param([string] $Scenario)
        $link = New-ModemWorkerLink
        $worker = New-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario $Scenario) -DataFolder (Join-Path $TestDrive ([guid]::NewGuid()))
        try {
            Invoke-ModemWorkerCycle -Worker $worker
            ConvertTo-WindowView -Snapshot $link['Snapshot']
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $link
        }
    }

    function Invoke-Click {
        param([object] $Button)
        $Button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }

    function Get-Plain {
        param([securestring] $Secret)
        [System.Net.NetworkCredential]::new('', $Secret).Password
    }

    $script:views = @{}
    foreach ($scenario in 'Online', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice') {
        $script:views[$scenario] = Get-ScenarioView -Scenario $scenario
    }
}

AfterAll {
    Remove-Module FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'The main window' {
    BeforeEach {
        $script:sent = [System.Collections.Generic.List[object]]::new()
        $script:answer = $false
        $script:asked = 0
        $script:window = New-MainWindow -Send { param($kind, $parameter) $script:sent.Add([pscustomobject]@{ Kind = $kind; Parameter = $parameter }) } `
            -Ask { $script:asked++; $script:answer }
        $script:controls = $script:window.Controls
    }

    AfterEach {
        $script:window.Exiting = $true
        $script:window.Window.Close()
    }

    It 'shows the view of the <_> scenario' -ForEach @('Online', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice') {
        $view = $script:views[$_]
        Update-MainWindow -View $view
        $script:controls.TitleText.Text | Should -Be $view.Title
        $script:controls.DetailText.Text | Should -Be $view.Detail
        $script:controls.BlockerPanel.Visibility | Should -Be $(if ($view.Blocker) { 'Visible' } else { 'Collapsed' })
        @($script:controls.CellsGrid.ItemsSource).Count | Should -Be @($view.Cells).Count
    }

    It 'fills the connection form from the settings, and leaves it alone while the user types' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.MetricBox.Text | Should -Be '500'
        $script:controls.PdpTypeBox.SelectedItem.Content | Should -Be 'IPV4V6'
        $script:controls.ApnBox.Text = 'typing'
        Update-MainWindow -View $script:views['Online']
        $script:controls.ApnBox.Text | Should -Be 'typing'
        Invoke-Click $script:controls.ReloadSettingsButton
        $script:controls.ApnBox.Text | Should -Be ''
    }

    It 'checks the connection now' {
        Invoke-Click $script:controls.CheckNowButton
        $script:sent.Kind | Should -Be @('ConnectNow')
    }

    It 'saves the APN the blocker asks for' {
        Update-MainWindow -View $script:views['ApnNeeded']
        $script:controls.BlockerInput.Visibility | Should -Be 'Visible'
        $script:controls.BlockerInput.Text = ' internet '
        Invoke-Click $script:controls.BlockerButton
        $script:sent.Kind | Should -Be @('SaveSettings')
        $script:sent[0].Parameter.Settings.Apn | Should -Be 'internet'
        $script:sent[0].Parameter.Settings.InterfaceMetric | Should -Be 500
    }

    It 'stores the PIN the blocker asks for, and empties the box' {
        Update-MainWindow -View $script:views['PinRequired']
        $script:controls.BlockerSecret.Visibility | Should -Be 'Visible'
        $script:controls.BlockerSecret.Password = '1234'
        Invoke-Click $script:controls.BlockerButton
        $script:sent.Kind | Should -Be @('SaveSimPin')
        Get-Plain $script:sent[0].Parameter.Pin | Should -Be '1234'
        $script:controls.BlockerSecret.Password | Should -Be ''
    }

    It 'unlocks the FCC lock only after the user confirmed it' {
        Update-MainWindow -View $script:views['FccLocked']
        Invoke-Click $script:controls.BlockerButton
        $script:asked | Should -Be 1
        $script:sent | Should -BeNullOrEmpty
        $script:answer = $true
        Invoke-Click $script:controls.BlockerButton
        $script:sent.Kind | Should -Be @('UnlockFcc')
    }

    It 'enables the adapter when asked' {
        Update-MainWindow -View $script:views['AdapterDisabled']
        Invoke-Click $script:controls.BlockerButton
        $script:sent.Kind | Should -Be @('EnableAdapter')
    }

    It 'removes the PIN from the SIM only with the PIN typed, and after the user confirmed it' {
        Update-MainWindow -View $script:views['Online']
        Invoke-Click $script:controls.DisablePinButton
        $script:asked | Should -Be 0
        $script:controls.SimNoteText.Text | Should -Match 'PIN first'
        $script:controls.SimPinBox.Password = '1234'
        Invoke-Click $script:controls.DisablePinButton
        $script:asked | Should -Be 1
        $script:sent | Should -BeNullOrEmpty
        $script:answer = $true
        Invoke-Click $script:controls.DisablePinButton
        $script:sent.Kind | Should -Be @('DisableSimPin')
        Get-Plain $script:sent[0].Parameter.Pin | Should -Be '1234'
    }

    It 'stores and forgets the PIN from the SIM tab' {
        $script:controls.SimPinBox.Password = '4321'
        Invoke-Click $script:controls.StorePinButton
        Invoke-Click $script:controls.ForgetPinButton
        $script:sent.Kind | Should -Be @('SaveSimPin', 'ForgetSimPin')
        Get-Plain $script:sent[0].Parameter.Pin | Should -Be '4321'
    }

    It 'refuses invalid settings at once, and sends nothing' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.MetricBox.Text = 'abc'
        Invoke-Click $script:controls.SaveSettingsButton
        $script:controls.SettingsProblemText.Text | Should -Match 'InterfaceMetric'
        $script:sent | Should -BeNullOrEmpty
    }

    It 'saves valid settings, with a new APN password or none' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.ApnBox.Text = 'internet'
        $script:controls.DnsBox.Text = '192.0.2.1, 192.0.2.2'
        $script:controls.ApnPasswordBox.Password = 'secret'
        Invoke-Click $script:controls.SaveSettingsButton
        $script:controls.ClearPasswordBox.IsChecked = $true
        Invoke-Click $script:controls.SaveSettingsButton
        Invoke-Click $script:controls.SaveSettingsButton
        $script:sent.Kind | Should -Be @('SaveSettings', 'SaveSettings', 'SaveSettings')
        $script:sent[0].Parameter.Settings.Apn | Should -Be 'internet'
        $script:sent[0].Parameter.Settings.DnsServers | Should -Be @('192.0.2.1', '192.0.2.2')
        Get-Plain $script:sent[0].Parameter.ApnPassword | Should -Be 'secret'
        $script:sent[1].Parameter.ApnPassword.Length | Should -Be 0 -Because 'an empty password deletes the stored one'
        $script:sent[2].Parameter.ContainsKey('ApnPassword') | Should -BeFalse -Because 'the stored password is kept'
    }
}
