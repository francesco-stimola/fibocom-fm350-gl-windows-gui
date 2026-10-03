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
    foreach ($scenario in 'Online', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'NoDriver') {
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
        $script:chosen = $null
        $script:opened = [System.Collections.Generic.List[string]]::new()
        $script:window = New-MainWindow -Send { param($kind, $parameter) $script:sent.Add([pscustomobject]@{ Kind = $kind; Parameter = $parameter }) } `
            -Ask { $script:asked++; $script:answer } -Choose { $script:chosen } -Open { param($url) $script:opened.Add($url) }
        $script:controls = $script:window.Controls
    }

    AfterEach {
        $script:window.Exiting = $true
        $script:window.Window.Close()
    }

    It 'shows the view of the <_> scenario' -ForEach @('Online', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'NoDriver') {
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

    It 'opens the Driver tab from the blocker when the AT port has no driver' {
        Update-MainWindow -View $script:views['NoDriver']
        $script:controls.BlockerButton.Content | Should -Be 'Install the driver...'
        Invoke-Click $script:controls.BlockerButton
        $script:controls.Tabs.SelectedItem | Should -Be $script:controls.DriverTab
        $script:sent | Should -BeNullOrEmpty
    }

    It 'shows the Driver tab: where a copy is, the package chosen, what can be done' {
        Update-MainWindow -View $script:views['NoDriver']
        $script:controls.DriverStateText.Text | Should -Be $script:views['NoDriver'].Driver.StateText
        $script:controls.DriverSourceText.Text | Should -BeLike '*third party*'
        $script:controls.OpenDriverPageButton.IsEnabled | Should -BeTrue
        $script:controls.ChooseDriverButton.IsEnabled | Should -BeTrue
        $script:controls.InstallDriverButton.IsEnabled | Should -BeFalse
        $script:controls.UninstallDriverButton.IsEnabled | Should -BeFalse
        $script:controls.DriverPackageText.Visibility | Should -Be 'Collapsed'
        Update-MainWindow -View $script:views['Online']
        $script:controls.UninstallDriverButton.IsEnabled | Should -BeTrue
    }

    It 'opens the page where the known copy is published' {
        Update-MainWindow -View $script:views['NoDriver']
        Invoke-Click $script:controls.OpenDriverPageButton
        $script:opened | Should -Be @($script:views['NoDriver'].Driver.PageUrl)
        $script:opened[0] | Should -BeLike 'https://github.com/*/blob/*'
    }

    It 'sends the package the user chose to be checked, and nothing when they choose none' {
        Update-MainWindow -View $script:views['NoDriver']
        Invoke-Click $script:controls.ChooseDriverButton
        $script:sent | Should -BeNullOrEmpty
        $script:chosen = 'C:\Users\Example\Downloads\driver.zip'
        Invoke-Click $script:controls.ChooseDriverButton
        $script:sent.Kind | Should -Be @('CheckDriverPackage')
        $script:sent[0].Parameter.Path | Should -Be 'C:\Users\Example\Downloads\driver.zip'
    }

    It 'installs a version the app knows at once, and one it doesn''t only after the user accepted it' {
        $view = $script:views['NoDriver'] | Select-Object -Property *
        $view.Driver = $view.Driver | Select-Object -Property *
        $view.Driver.CanInstall = $true
        Update-MainWindow -View $view
        Invoke-Click $script:controls.InstallDriverButton
        $script:asked | Should -Be 0
        $script:sent[0].Kind | Should -Be 'InstallDriver'
        $script:sent[0].Parameter.ContainsKey('AcceptUnknown') | Should -BeFalse

        $script:sent.Clear()
        $view.Driver.ConfirmInstall = $true
        Update-MainWindow -View $view
        $script:controls.InstallDriverButton.Content | Should -Be 'Install...'
        Invoke-Click $script:controls.InstallDriverButton
        $script:asked | Should -Be 1
        $script:sent | Should -BeNullOrEmpty
        $script:answer = $true
        Invoke-Click $script:controls.InstallDriverButton
        $script:sent[0].Parameter.AcceptUnknown | Should -BeTrue
    }

    It 'uninstalls the driver only after the user confirmed it' {
        Update-MainWindow -View $script:views['Online']
        Invoke-Click $script:controls.UninstallDriverButton
        $script:asked | Should -Be 1
        $script:sent | Should -BeNullOrEmpty
        $script:answer = $true
        Invoke-Click $script:controls.UninstallDriverButton
        $script:sent.Kind | Should -Be @('UninstallDriver')
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

    It 'fills the network tab: the modem''s mode, every choice, a checkbox per band' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.CurrentModeText.Text | Should -Be 'The modem now: 4G + 5G. LTE: every band. NR: every band but n77.'
        @($script:controls.NetworkModeBox.Items).Count | Should -Be 4
        $script:controls.NetworkModeBox.SelectedItem.Name | Should -Be '' -Because 'the app doesn''t manage the mode by default'
        $script:controls.LteBandsPanel.Children.Count | Should -Be 31
        $script:controls.NrBandsPanel.Children.Count | Should -Be 19
        $script:controls.LteBandsPanel.Children[2].Content | Should -Be 'B3'
        $script:controls.LteAllBox.IsChecked | Should -BeTrue
        $script:controls.BandsPanel.IsEnabled | Should -BeFalse -Because 'bands go with a mode the app manages'
        $script:controls.ApplyModeButton.IsEnabled | Should -BeTrue
    }

    It 'applies the mode and bands chosen' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.NetworkModeBox.SelectedItem = @($script:controls.NetworkModeBox.Items | Where-Object Name -EQ 'Automatic')[0]
        $script:controls.BandsPanel.IsEnabled | Should -BeTrue
        $script:controls.LteAllBox.IsChecked = $false
        Invoke-Click $script:controls.LteAllBox
        $script:controls.LteAllBox.IsChecked = $false
        $script:controls.LteBandsPanel.IsEnabled | Should -BeTrue
        foreach ($box in $script:controls.LteBandsPanel.Children) { $box.IsChecked = $box.Content -in 'B3', 'B20' }
        Invoke-Click $script:controls.ApplyModeButton
        $script:sent.Kind | Should -Be @('SetNetworkMode')
        $script:sent[0].Parameter.NetworkMode | Should -Be 'Automatic'
        $script:sent[0].Parameter.LteBands | Should -Be @(3, 20)
        @($script:sent[0].Parameter.NrBands).Count | Should -Be 0 -Because 'every NR band'
    }

    It 'asks for a band at least, and sends nothing without one' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.NetworkModeBox.SelectedItem = @($script:controls.NetworkModeBox.Items | Where-Object Name -EQ 'NrOnly')[0]
        $script:controls.NrAllBox.IsChecked = $false
        foreach ($box in $script:controls.NrBandsPanel.Children) { $box.IsChecked = $false }
        Invoke-Click $script:controls.ApplyModeButton
        $script:sent | Should -BeNullOrEmpty
        $script:controls.ModeNoteText.Text | Should -Match 'at least one NR band'
    }

    It 'keeps the bands of a RAT the mode doesn''t use out of reach: <Mode>' -ForEach @(
        @{ Mode = 'LteOnly'; Lte = $true; Nr = $false }
        @{ Mode = 'NrOnly'; Lte = $false; Nr = $true }
    ) {
        Update-MainWindow -View $script:views['Online']
        $script:controls.NetworkModeBox.SelectedItem = @($script:controls.NetworkModeBox.Items | Where-Object Name -EQ $Mode)[0]
        $script:controls.LteAllBox.IsEnabled | Should -Be $Lte
        $script:controls.NrAllBox.IsEnabled | Should -Be $Nr
    }

    It 'stops managing the mode when "as the modem has it" is applied' {
        Update-MainWindow -View $script:views['Online']
        Invoke-Click $script:controls.ApplyModeButton
        $script:sent.Kind | Should -Be @('SetNetworkMode')
        $script:sent[0].Parameter.NetworkMode | Should -Be ''
    }

    It 'can''t apply a mode without a modem' {
        Update-MainWindow -View $script:views['NoDevice']
        $script:controls.ApplyModeButton.IsEnabled | Should -BeFalse
    }

    It 'offers 4G + 5G with every band when a narrowed mode finds no network' {
        $view = $script:views['Online'] | Select-Object -Property *
        $view.Blocker = [pscustomobject]@{ Kind = 'NetworkMode'; Message = 'No network found with 5G only (SA).'; ActionText = 'Use 4G + 5G, every band'; Enabled = $true }
        Update-MainWindow -View $view
        $script:controls.BlockerButton.Content | Should -Be 'Use 4G + 5G, every band'
        Invoke-Click $script:controls.BlockerButton
        $script:sent.Kind | Should -Be @('SetNetworkMode')
        $script:sent[0].Parameter.NetworkMode | Should -Be 'Automatic'
        @($script:sent[0].Parameter.LteBands).Count | Should -Be 0
        @($script:sent[0].Parameter.NrBands).Count | Should -Be 0
    }
}
