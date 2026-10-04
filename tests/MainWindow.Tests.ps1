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
        # Send gives back the command's Id, as the app's does.
        $script:window = New-MainWindow -Send { param($kind, $parameter) $script:sent.Add([pscustomobject]@{ Kind = $kind; Parameter = $parameter }); "id-$($script:sent.Count)" } `
            -Ask { $script:asked++; $script:answer } -Choose { $script:chosen } -Open { param($url) $script:opened.Add($url) }
        $script:controls = $script:window.Controls
    }

    AfterEach {
        $script:window.Exiting = $true
        $script:window.Window.Close()
    }

    It 'carries the app''s icon, for the title bar and the taskbar' {
        $script:window.Window.Icon.Decoder.Frames.Count | Should -Be 8
    }

    It 'is titled with the program''s name, as the Start menu and the list of installed apps show it' {
        $script:window.Window.Title | Should -BeExactly 'Fibocom FM350-GL Windows GUI'
        $installer = Import-Module "$PSScriptRoot/../src/Installer/FibocomFm350.Installer.psd1" -PassThru -Force
        try {
            & $installer { $script:DisplayName } | Should -BeExactly $script:window.Window.Title
        }
        finally {
            Remove-Module -ModuleInfo $installer
        }
    }

    It 'is the app''s on the taskbar, and takes that off before it closes' {
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($script:window.Window).Handle
        [FibocomFm350.AppIdentity]::GetWindowId($handle) | Should -Be 'FibocomFm350Gl.WindowsGui'
        # Run after the window's own handler: what is left when the window closes.
        $script:left = 'not read'
        $script:window.Window.Add_Closing({ $script:left = [FibocomFm350.AppIdentity]::GetWindowId([System.Windows.Interop.WindowInteropHelper]::new($args[0]).Handle) })
        $script:window.Exiting = $true
        $script:window.Window.Close()
        $script:left | Should -BeNullOrEmpty -Because 'a window''s properties are taken off before it closes'
    }

    It 'scrolls the <_> tab when the window is too small for it' -ForEach @('ConnectionTab', 'DriverTab', 'SimTab', 'DataTab', 'EsimTab') {
        $tab = $script:window.Window.FindName($_)
        $tab.Content | Should -BeOfType ([System.Windows.Controls.ScrollViewer])
        $tab.Content.VerticalScrollBarVisibility | Should -Be 'Auto'
    }

    It 'needs that scroll: the Connection tab''s fields are taller than the smallest window' {
        $fields = $script:controls.ConnectionTab.Content.Content
        $fields.Measure([System.Windows.Size]::new(500, [double]::PositiveInfinity))
        $fields.DesiredSize.Height | Should -BeGreaterThan $script:window.Window.MinHeight
    }

    It 'wraps the outcome and the footer beside the Check now button, never under it' {
        $script:controls.FooterText.TextWrapping | Should -Be 'Wrap'
        $script:controls.ResultText.TextWrapping | Should -Be 'Wrap'
        [System.Windows.Controls.DockPanel]::GetDock($script:controls.CheckNowButton) | Should -Be 'Right'
        $script:controls.CheckNowButton.Margin.Left | Should -BeGreaterThan 0
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
        $script:sent[0].Parameter.SimToken | Should -Be $script:views['ApnNeeded'].SimToken -Because 'the APN is the SIM in use''s'
    }

    It 'says whose APN settings the form shows, and saves them for that SIM' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.ApnSimText.Text | Should -Be $script:views['Online'].ApnSimText
        $script:controls.ApnBox.IsEnabled | Should -BeTrue
        $script:controls.ApnBox.Text = 'internet'
        Invoke-Click $script:controls.SaveSettingsButton
        $script:sent[0].Parameter.SimToken | Should -Be $script:views['Online'].SimToken
        $script:sent[0].Parameter.SimToken | Should -Not -BeNullOrEmpty
    }

    It 'fills the APN settings again when another SIM is in use, the rest of the form as typed' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.ApnBox.Text = 'typed for the first SIM'
        $script:controls.MetricBox.Text = '42'
        $other = $script:views['Online'] | Select-Object -Property *
        $other.SimToken = 'another-sim'
        $other.Settings = $other.Settings | Select-Object -Property *
        $other.Settings.Apn = 'its.own'
        Update-MainWindow -View $other
        $script:controls.ApnBox.Text | Should -Be 'its.own'
        $script:controls.MetricBox.Text | Should -Be '42'
        Invoke-Click $script:controls.SaveSettingsButton
        $script:sent[0].Parameter.SimToken | Should -Be 'another-sim'
        $script:sent[0].Parameter.Settings.Apn | Should -Be 'its.own'
    }

    It 'keeps the APN settings out of reach while no SIM is identified, the others not' {
        $none = $script:views['Online'] | Select-Object -Property *
        $none.SimToken = $null
        $none.ApnEditable = $false
        $none.ApnSimText = 'No SIM ready.'
        Update-MainWindow -View $none
        foreach ($name in 'ApnBox', 'PdpTypeBox', 'AuthenticationBox', 'ApnUserBox', 'ApnPasswordBox', 'ClearPasswordBox') {
            $script:controls.$name.IsEnabled | Should -BeFalse -Because $name
        }
        $script:controls.DnsBox.IsEnabled | Should -BeTrue
        $script:controls.ApnSimText.Text | Should -Be 'No SIM ready.'
        # Saved without them: the worker keeps them as they are, whatever SIM is in use by then.
        $script:controls.MetricBox.Text = '42'
        $script:controls.ApnPasswordBox.Password = 'left from before'
        Invoke-Click $script:controls.SaveSettingsButton
        $sent = $script:sent[0].Parameter
        $sent.Settings.InterfaceMetric | Should -Be 42
        $sent.Settings.PSObject.Properties['Apn'] | Should -BeNullOrEmpty
        $sent.ContainsKey('ApnPassword') | Should -BeFalse
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

    It 'fills encrypted DNS and the update notice from the settings, and sends them' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.DohBox.IsChecked | Should -BeFalse
        $script:controls.DohTemplateBox.Text | Should -Be ''
        $script:controls.UpdateCheckBox.IsChecked | Should -BeTrue
        $script:controls.DohStateText.Text | Should -Be 'Encrypted DNS is off.'
        $script:controls.DohBox.IsEnabled | Should -BeTrue
        $script:controls.DnsBox.Text = '1.1.1.1, 9.9.9.9'
        $script:controls.DohBox.IsChecked = $true
        $script:controls.UpdateCheckBox.IsChecked = $false
        Invoke-Click $script:controls.SaveSettingsButton
        $script:controls.SettingsProblemText.Text | Should -Be ''
        $settings = $script:sent[0].Parameter.Settings
        $settings.DnsOverHttps | Should -BeTrue
        $settings.DnsServers | Should -Be @('1.1.1.1', '9.9.9.9')
        $settings.CheckForUpdates | Should -BeFalse
    }

    It 'refuses encrypted DNS for a server Windows knows no template for, unless one is given' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.DnsBox.Text = '1.1.1.1, 203.0.113.53'
        $script:controls.DohBox.IsChecked = $true
        Invoke-Click $script:controls.SaveSettingsButton
        $script:controls.SettingsProblemText.Text | Should -Match 'no DNS-over-HTTPS template for 203\.0\.113\.53'
        $script:sent | Should -BeNullOrEmpty
        $script:controls.DohTemplateBox.Text = 'https://dns.example/dns-query'
        Invoke-Click $script:controls.SaveSettingsButton
        $script:sent.Count | Should -Be 1
        $script:sent[0].Parameter.Settings.DohTemplate | Should -Be 'https://dns.example/dns-query'
    }

    It 'refuses encrypted DNS without servers of the user''s' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.DnsBox.Text = ''
        $script:controls.DohBox.IsChecked = $true
        Invoke-Click $script:controls.SaveSettingsButton
        $script:controls.SettingsProblemText.Text | Should -Match 'DnsOverHttps needs DnsServers'
        $script:sent | Should -BeNullOrEmpty
    }

    It 'takes encrypted DNS to a server the template names, and how often its name is looked up' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.DohRefreshBox.Text | Should -Be '60'
        $script:controls.DnsBox.Text = ''
        $script:controls.DohBox.IsChecked = $true
        $script:controls.DohTemplateBox.Text = 'https://dns.example.org/dns-query'
        $script:controls.DohRefreshBox.Text = ' 15 '
        Invoke-Click $script:controls.SaveSettingsButton
        $script:controls.SettingsProblemText.Text | Should -Be ''
        $settings = $script:sent[0].Parameter.Settings
        @($settings.DnsServers).Count | Should -Be 0
        $settings.DohTemplate | Should -Be 'https://dns.example.org/dns-query'
        $settings.DohRefreshMinutes | Should -Be 15
    }

    It 'refuses an interval it can''t take, and says so' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.DohRefreshBox.Text = '2'
        Invoke-Click $script:controls.SaveSettingsButton
        $script:controls.SettingsProblemText.Text | Should -Match 'DohRefreshMinutes must be a whole number of minutes from 5 to 1440'
        $script:sent | Should -BeNullOrEmpty
    }

    It 'only lets encrypted DNS be turned off where Windows can''t set it' {
        $view = $script:views['Online'] | Select-Object -Property *
        $view.Dns = [pscustomobject]@{ Text = 'Encrypted DNS is not available on this Windows.'; CanEnable = $false; Known = [string[]]@() }
        Update-MainWindow -View $view
        $script:controls.DohBox.IsEnabled | Should -BeFalse
        $script:controls.DohStateText.Text | Should -Match 'not available'
        $script:controls.DnsBox.Text = '1.1.1.1'
        $script:controls.DohBox.IsChecked = $true
        Invoke-Click $script:controls.SaveSettingsButton
        $script:controls.SettingsProblemText.Text | Should -Match 'not available on this Windows'
        $script:sent | Should -BeNullOrEmpty
    }

    It 'opens the Connection tab from an encrypted-DNS blocker' {
        $view = $script:views['Online'] | Select-Object -Property *
        $view.Blocker = [pscustomobject]@{ Kind = 'Settings'; Message = 'x'; ActionText = 'Open the settings'; Enabled = $true }
        Update-MainWindow -View $view
        $script:controls.BlockerButton.Content | Should -Be 'Open the settings'
        Invoke-Click $script:controls.BlockerButton
        $script:controls.Tabs.SelectedItem | Should -Be $script:controls.ConnectionTab
        $script:sent | Should -BeNullOrEmpty
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

    It 'shows the Messages tab: how full the SIM is, the list, the new ones counted in its header' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.MessagesTab.Header | Should -Be 'Messages (2)'
        $script:controls.MessagesStateText.Text | Should -Be 'SIM in use: slot 1, a physical SIM. 4 of 70 places used on the SIM.'
        $script:controls.MessageFromText.Text | Should -Match '^A message goes out from the SIM in use'
        @($script:controls.MessagesGrid.ItemsSource).Count | Should -Be 3
        $script:controls.MessagesGrid.SelectedItem | Should -BeNullOrEmpty
        $script:controls.DeleteMessageButton.IsEnabled | Should -BeFalse -Because 'nothing is selected'
        $script:controls.SendMessageButton.IsEnabled | Should -BeTrue
    }

    It 'opens a new message the user selects, again when selected again, and shows it' {
        Update-MainWindow -View $script:views['Online']
        $items = @($script:controls.MessagesGrid.ItemsSource)
        $script:controls.MessagesGrid.SelectedItem = $items[0]
        $script:controls.MessagesGrid.SelectedItem = $items[2]
        $script:controls.MessagesGrid.SelectedItem = $items[0]

        $script:sent.Kind | Should -Be @('OpenMessage', 'OpenMessage') -Because 'a command lost with a worker that ended is sent again; a message already read is not opened'
        $script:sent[0].Parameter.Fingerprints | Should -Be $items[0].Fingerprints
        $script:controls.MessageHeaderText.Text | Should -Be $items[0].Header
        $script:controls.MessageBodyText.Text | Should -Be $items[0].Text
        $script:controls.DeleteMessageButton.IsEnabled | Should -BeTrue
    }

    It 'keeps the selection when the list is filled again, opening nothing' {
        $view = $script:views['Online']
        Update-MainWindow -View $view
        $script:controls.MessagesGrid.SelectedItem = @($script:controls.MessagesGrid.ItemsSource)[2]
        $refreshed = $view | Select-Object -Property *
        $messages = $view.Messages | Select-Object -Property *
        $messages.Items = [object[]]@($view.Messages.Items | ForEach-Object { $row = $_ | Select-Object -Property *; $row.New = $false; $row })
        $refreshed.Messages = $messages
        Update-MainWindow -View $refreshed

        $script:controls.MessagesGrid.SelectedItem.Key | Should -Be $view.Messages.Items[2].Key
        $script:sent | Should -BeNullOrEmpty
        $script:controls.MessageHeaderText.Text | Should -Be $view.Messages.Items[2].Header
    }

    It 'deletes the selected message only after the user confirmed it' {
        Update-MainWindow -View $script:views['Online']
        $item = @($script:controls.MessagesGrid.ItemsSource)[2]
        $script:controls.MessagesGrid.SelectedItem = $item
        Invoke-Click $script:controls.DeleteMessageButton
        $script:sent | Should -BeNullOrEmpty
        $script:answer = $true
        Invoke-Click $script:controls.DeleteMessageButton

        $script:asked | Should -Be 2
        $script:sent.Kind | Should -Be @('DeleteMessage')
        $script:sent[0].Parameter.Fingerprints | Should -Be $item.Fingerprints
    }

    It 'sends the number and the text as typed, and keeps the text until the message is sent' {
        $view = $script:views['Online']
        Update-MainWindow -View $view
        $script:controls.MessageToBox.Text = ' +10000000000 '
        $script:controls.MessageTextBox.Text = 'hello'
        Invoke-Click $script:controls.SendMessageButton
        $script:sent.Kind | Should -Be @('SendMessage')
        $script:sent[0].Parameter.Number | Should -Be '+10000000000'
        $script:sent[0].Parameter.Text | Should -Be 'hello'
        $script:controls.MessageTextBox.Text | Should -Be 'hello' -Because 'it is not sent yet'

        $done = $view | Select-Object -Property *
        $done.Messages = $view.Messages | Select-Object -Property *
        $done.Messages.SentId = 'sent-1'
        Update-MainWindow -View $done
        $script:controls.MessageTextBox.Text | Should -Be '' -Because 'the message is sent'
        $script:controls.MessageToBox.Text | Should -Be ' +10000000000 ' -Because 'the number may serve again'
    }

    It 'keeps a new text typed while the last message went out' {
        $view = $script:views['Online']
        Update-MainWindow -View $view
        $script:controls.MessageToBox.Text = '+10000000000'
        $script:controls.MessageTextBox.Text = 'hello'
        Invoke-Click $script:controls.SendMessageButton
        $script:controls.MessageTextBox.Text = 'another one'
        $done = $view | Select-Object -Property *
        $done.Messages = $view.Messages | Select-Object -Property *
        $done.Messages.SentId = 'sent-1'
        Update-MainWindow -View $done

        $script:controls.MessageTextBox.Text | Should -Be 'another one'
    }

    It 'sends a message once, however many times Send is clicked before the worker answers' {
        $view = $script:views['Online']
        Update-MainWindow -View $view
        $script:controls.MessageToBox.Text = '+10000000000'
        $script:controls.MessageTextBox.Text = 'hello'
        Invoke-Click $script:controls.SendMessageButton
        Invoke-Click $script:controls.SendMessageButton
        $script:controls.SendMessageButton.IsEnabled | Should -BeFalse
        Update-MainWindow -View $view
        Invoke-Click $script:controls.SendMessageButton
        $script:sent.Kind | Should -Be @('SendMessage') -Because 'the worker has not answered it yet'
        $script:controls.SendMessageButton.IsEnabled | Should -BeFalse

        $answered = $view | Select-Object -Property *
        $answered.Messages = $view.Messages | Select-Object -Property *
        $answered.Messages.SendIds = [string[]]@('id-1')
        Update-MainWindow -View $answered
        $script:controls.SendMessageButton.IsEnabled | Should -BeTrue
        Invoke-Click $script:controls.SendMessageButton
        $script:sent.Kind | Should -Be @('SendMessage', 'SendMessage') -Because 'once answered, the user may send it again'
    }

    It 'can send again once another worker took over: the command went with the one that ended' {
        $view = $script:views['Online']
        Update-MainWindow -View $view
        $script:controls.MessageToBox.Text = '+10000000000'
        $script:controls.MessageTextBox.Text = 'hello'
        Invoke-Click $script:controls.SendMessageButton
        $next = $view | Select-Object -Property *
        $next.Messages = $view.Messages | Select-Object -Property *
        $next.Messages.Generation = [int]$view.Messages.Generation + 1
        Update-MainWindow -View $next
        $script:controls.SendMessageButton.IsEnabled | Should -BeTrue
    }

    It 'takes a text of 255 parts at most' {
        $script:controls.MessageTextBox.MaxLength | Should -Be (255 * 153)
    }

    It 'asks for a number and a text, and sends nothing without them' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.MessageTextBox.Text = 'hello'
        Invoke-Click $script:controls.SendMessageButton
        $script:controls.MessageCountText.Text | Should -Be 'Enter a phone number and a text.'
        $script:sent | Should -BeNullOrEmpty
    }

    It 'counts the characters and the parts as the text is typed' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.MessageTextBox.Text = 'x' * 161
        $script:controls.MessageCountText.Text | Should -Be 'Characters: 161 - parts: 2'
        $script:controls.MessageTextBox.Text = ''
        $script:controls.MessageCountText.Text | Should -Be ''
    }

    It 'says a message is going out, and sends no other meanwhile' {
        $view = $script:views['Online']
        $sending = $view | Select-Object -Property *
        $sending.Messages = $view.Messages | Select-Object -Property *
        $sending.Messages.SendingText = 'Sending the message...'
        $sending.Messages.CanSend = $false
        Update-MainWindow -View $sending
        $script:controls.MessageCountText.Text | Should -Be 'Sending the message...'
        $script:controls.SendMessageButton.IsEnabled | Should -BeFalse
    }

    It 'sends nothing without a modem, and says why' {
        Update-MainWindow -View $script:views['NoDevice']
        $script:controls.SendMessageButton.IsEnabled | Should -BeFalse
        $script:controls.MessagesStateText.Text | Should -Be 'The modem is not connected.'
        $script:controls.MessagesTab.Header | Should -Be 'Messages'
    }

    It 'shows the data used, and fills the cycle''s first day and the quota from the settings' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.UsageTodayText.Text | Should -Be 'Today: 0 B (received 0 B, sent 0 B)'
        $script:controls.UsageCycleText.Text | Should -Match '^This cycle, from \d{4}-\d{2}-01 to '
        $script:controls.UsageQuotaText.Text | Should -Be 'No quota set.'
        $script:controls.UsageQuotaBar.Visibility | Should -Be 'Collapsed'
        $script:controls.CycleDayBox.Text | Should -Be '1'
        $script:controls.QuotaBox.Text | Should -Be '0'
    }

    It 'shows the quota''s bar, red from a threshold on' {
        $view = $script:views['Online'] | Select-Object -Property *
        $view.Usage = [pscustomobject]@{ TodayText = 'today'; CycleText = 'cycle'; QuotaText = 'quota'; Percent = 85.5; Warning = $true }
        Update-MainWindow -View $view
        $script:controls.UsageQuotaBar.Visibility | Should -Be 'Visible'
        $script:controls.UsageQuotaBar.Value | Should -Be 85.5
        $script:controls.UsageQuotaBar.Foreground.Color.ToString() | Should -Be '#FFC0392B'
    }

    It 'leaves the Data tab''s form alone while the user types' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.CycleDayBox.Text = '9'
        Update-MainWindow -View $script:views['Online']
        $script:controls.CycleDayBox.Text | Should -Be '9'
    }

    It 'saves the cycle''s first day and the quota - a decimal comma as a point -, the other settings as saved' {
        $view = $script:views['Online'] | Select-Object -Property *
        $saved = $view.Settings | Select-Object -Property *
        $saved.Apn = 'internet'
        $view.Settings = $saved
        Update-MainWindow -View $view
        $script:controls.ApnBox.Text = 'typed, not saved'
        $script:controls.CycleDayBox.Text = '15'
        $script:controls.QuotaBox.Text = '2,5'
        Invoke-Click $script:controls.SaveUsageButton

        $script:controls.UsageProblemText.Text | Should -Be ''
        $script:sent.Kind | Should -Be @('SaveSettings')
        $settings = $script:sent[0].Parameter.Settings
        $settings.UsageCycleDay | Should -Be 15
        $settings.UsageQuotaGB | Should -Be 2.5
        $settings.InterfaceMetric | Should -Be 500
        foreach ($name in 'Apn', 'PdpType', 'ApnAuthentication', 'ApnUser') {
            $settings.PSObject.Properties[$name] | Should -BeNullOrEmpty -Because "$name is the SIM in use's, which the worker keeps as it is"
        }
    }

    It 'refuses a cycle day it can''t take, and says so' {
        Update-MainWindow -View $script:views['Online']
        $script:controls.CycleDayBox.Text = '32'
        Invoke-Click $script:controls.SaveUsageButton
        $script:controls.UsageProblemText.Text | Should -Match 'UsageCycleDay'
        $script:sent | Should -BeNullOrEmpty
    }

    It 'keeps the data usage settings as saved when the connection is saved' {
        $view = $script:views['Online'] | Select-Object -Property *
        $settings = $view.Settings | Select-Object -Property *
        $settings.UsageCycleDay = 10
        $settings.UsageQuotaGB = 5.5
        $view.Settings = $settings
        Update-MainWindow -View $view
        $script:controls.CycleDayBox.Text = '20'
        Invoke-Click $script:controls.SaveSettingsButton

        $script:sent[0].Parameter.Settings.UsageCycleDay | Should -Be 10
        $script:sent[0].Parameter.Settings.UsageQuotaGB | Should -Be 5.5
    }
}

Describe 'The eSIM tab' {
    BeforeAll {
        # The view after the cycles that read the eUICC.
        function Get-EsimScenarioView {
            param([string] $Scenario)
            $link = New-ModemWorkerLink
            $device = New-SimulatedDevice -Scenario $Scenario
            $device.Modem.Euicc.ResetMs = 0
            $worker = New-ModemWorker -Link $link -Simulation $device -DataFolder (Join-Path $TestDrive ([guid]::NewGuid()))
            try {
                for ($i = 0; $i -lt 3; $i++) { Invoke-ModemWorkerCycle -Worker $worker }
                ConvertTo-WindowView -Snapshot $link['Snapshot']
            }
            finally {
                Close-ModemWorker -Worker $worker
                Close-ModemWorkerLink -Link $link
            }
        }

        # A copy of a view whose eSIM has some properties changed.
        function Copy-EsimView {
            param([object] $View, [hashtable] $Change)
            $copy = $View | Select-Object -Property *
            $copy.Esim = $View.Esim | Select-Object -Property *
            foreach ($key in $Change.Keys) {
                $copy.Esim.$key = $Change[$key]
            }
            $copy
        }

        # A view whose last command outcome is this one.
        function Add-ViewResult {
            param([object] $View, [string] $Id, [string] $Kind, [string] $Result)
            $copy = Copy-EsimView -View $View -Change @{ ResultIds = [string[]]@($Id) }
            $copy.LastResult = [pscustomobject]@{ Id = $Id; Kind = $Kind; Result = $Result }
            $copy
        }

        $script:emptyView = Get-EsimScenarioView -Scenario EsimEmpty
        $script:esimView = Get-EsimScenarioView -Scenario Esim
        $script:physicalView = Get-EsimScenarioView -Scenario Online
    }

    BeforeEach {
        $script:sent = [System.Collections.Generic.List[object]]::new()
        $script:answer = $false
        $script:asked = [System.Collections.Generic.List[string]]::new()
        $script:typed = $false
        $script:confirmed = [System.Collections.Generic.List[string]]::new()
        $script:image = $null
        $script:copied = $null
        $script:clipboardBusy = $false
        $script:window = New-MainWindow -Send { param($kind, $parameter) $script:sent.Add([pscustomobject]@{ Kind = $kind; Parameter = $parameter }); "id-$($script:sent.Count)" } `
            -Ask { $script:asked.Add($args[1]); $script:answer } `
            -AskName { $script:confirmed.Add($args[2]); $script:typed } `
            -ChooseImage { $script:image } `
            -Copy { if ($script:clipboardBusy) { throw [System.Runtime.InteropServices.COMException]::new('OpenClipboard failed') }; $script:copied = $args[0] }
        $script:controls = $script:window.Controls
    }

    AfterEach {
        $script:window.Exiting = $true
        $script:window.Window.Close()
    }

    It 'shows the SIM in use in the top panel, the profiles, the EID and the other slot' {
        Update-MainWindow -View $script:emptyView
        $script:controls.SimInUseText.Text | Should -Be 'SIM in use: slot 2, the eSIM, no profile enabled.'
        $script:controls.SimInUseText.Visibility | Should -Be 'Visible'
        $script:controls.EsimSlotText.Text | Should -Be $script:controls.SimInUseText.Text
        @($script:controls.ProfilesGrid.ItemsSource).Count | Should -Be 1
        $script:controls.EidPanel.Visibility | Should -Be 'Visible'
        $script:controls.EidBox.Text | Should -Be $script:emptyView.Esim.Eid
        $script:controls.EidBox.IsReadOnly | Should -BeTrue
        $script:controls.UseEsimButton.Content | Should -Be 'In use: the eSIM (slot 2)'
        $script:controls.UseEsimButton.IsEnabled | Should -BeFalse -Because 'its SIM is in use'
        $script:controls.UsePhysicalButton.Content | Should -Be 'Use the physical SIM (slot 1)...'
        $script:controls.UsePhysicalButton.IsEnabled | Should -BeTrue
        $script:controls.SimSlotNoteText.Text | Should -Match '^The modem uses one SIM at a time'
        $script:controls.EsimSlotNoteText.Text | Should -Be $script:controls.SimSlotNoteText.Text
        $script:controls.EnableProfileButton.IsEnabled | Should -BeFalse -Because 'nothing is selected'
        $script:controls.DownloadProfileButton.IsEnabled | Should -BeTrue
    }

    It 'opens the eSIM tab from the blocker of an eSIM with no profile enabled' {
        Update-MainWindow -View $script:emptyView
        $script:controls.BlockerButton.Content | Should -Be 'Open eSIM'
        Invoke-Click $script:controls.BlockerButton
        $script:controls.Tabs.SelectedItem | Should -Be $script:controls.EsimTab
        $script:sent | Should -BeNullOrEmpty
    }

    It 'hides the eSIM''s EID and keeps its profiles out of reach while a physical SIM is in use' {
        Update-MainWindow -View $script:physicalView
        $script:controls.SimInUseText.Text | Should -Be 'SIM in use: slot 1, a physical SIM.'
        $script:controls.EidPanel.Visibility | Should -Be 'Collapsed'
        $script:controls.DownloadProfileButton.IsEnabled | Should -BeFalse
        $script:controls.ReadEsimButton.IsEnabled | Should -BeFalse
        $script:controls.UseEsimButton.Content | Should -Be 'Use the eSIM (slot 2)...'
        $script:controls.UseEsimButton.IsEnabled | Should -BeTrue
        $script:controls.UsePhysicalButton.Content | Should -Be 'In use: the physical SIM (slot 1)'
        $script:controls.UsePhysicalButton.IsEnabled | Should -BeFalse -Because 'its SIM is in use'
    }

    It 'switches to the physical SIM, from the SIM tab, only once the user said yes, No preselected' {
        Update-MainWindow -View $script:emptyView
        Invoke-Click $script:controls.UsePhysicalButton
        $script:sent | Should -BeNullOrEmpty
        $script:asked[0] | Should -Match '^Use SIM slot 1\?'
        $script:asked[0] | Should -Match 'keeps this choice'
        $script:answer = $true
        Invoke-Click $script:controls.UsePhysicalButton
        $script:sent.Kind | Should -Be @('SelectSimSlot')
        $script:sent[0].Parameter.Slot | Should -Be 0 -Because 'the worker counts slots from 0'
    }

    It 'switches to the eSIM from the eSIM tab, and never to the SIM in use' {
        $script:answer = $true
        Update-MainWindow -View $script:emptyView
        Invoke-Click $script:controls.UseEsimButton
        $script:sent | Should -BeNullOrEmpty -Because 'the eSIM is in use already'
        Update-MainWindow -View $script:physicalView
        Invoke-Click $script:controls.UseEsimButton
        $script:asked[-1] | Should -Match '^Use SIM slot 2\?'
        $script:sent.Kind | Should -Be @('SelectSimSlot')
        $script:sent[0].Parameter.Slot | Should -Be 1
    }

    It 'enables the profile selected once the user said yes, and offers what fits its state' {
        Update-MainWindow -View $script:esimView
        $rows = @($script:controls.ProfilesGrid.ItemsSource)
        $script:controls.ProfilesGrid.SelectedItem = $rows | Where-Object Enabled
        $script:controls.EnableProfileButton.IsEnabled | Should -BeFalse
        $script:controls.DisableProfileButton.IsEnabled | Should -BeTrue
        $script:controls.DeleteProfileButton.IsEnabled | Should -BeFalse -Because 'an enabled profile is never deleted'
        $script:controls.NicknameBox.Text | Should -Be 'Travel'
        $test = $rows | Where-Object { -not $_.Enabled }
        $script:controls.ProfilesGrid.SelectedItem = $test
        $script:controls.EnableProfileButton.IsEnabled | Should -BeTrue
        $script:controls.DisableProfileButton.IsEnabled | Should -BeFalse
        $script:controls.DeleteProfileButton.IsEnabled | Should -BeTrue
        $script:controls.NicknameBox.Text | Should -Be ''
        Invoke-Click $script:controls.EnableProfileButton
        $script:sent | Should -BeNullOrEmpty
        $script:answer = $true
        Invoke-Click $script:controls.EnableProfileButton
        $script:asked[1] | Should -Match '^Enable the profile "Lab test profile"\?'
        $script:sent.Kind | Should -Be @('EnableProfile')
        $script:sent[0].Parameter.Aid | Should -Be $test.Aid
    }

    It 'disables the profile selected once the user said yes' {
        Update-MainWindow -View $script:esimView
        $enabled = @($script:controls.ProfilesGrid.ItemsSource) | Where-Object Enabled
        $script:controls.ProfilesGrid.SelectedItem = $enabled
        $script:answer = $true
        Invoke-Click $script:controls.DisableProfileButton
        $script:asked[0] | Should -Match '^Disable the profile "Travel"\?'
        $script:sent.Kind | Should -Be @('DisableProfile')
        $script:sent[0].Parameter.Aid | Should -Be $enabled.Aid
    }

    It 'deletes a profile only once its name was typed' {
        Update-MainWindow -View $script:esimView
        $test = @($script:controls.ProfilesGrid.ItemsSource) | Where-Object { -not $_.Enabled }
        $script:controls.ProfilesGrid.SelectedItem = $test
        Invoke-Click $script:controls.DeleteProfileButton
        $script:sent | Should -BeNullOrEmpty
        $script:typed = $true
        Invoke-Click $script:controls.DeleteProfileButton
        $script:confirmed | Should -Be @('Lab test profile', 'Lab test profile')
        $script:sent.Kind | Should -Be @('DeleteProfile')
        $script:sent[0].Parameter.Aid | Should -Be $test.Aid
        $script:asked | Should -BeNullOrEmpty -Because 'a Yes is not enough to delete'
    }

    It 'renames the profile selected - blanks around taken off, none to clear it' {
        Update-MainWindow -View $script:esimView
        $test = @($script:controls.ProfilesGrid.ItemsSource) | Where-Object { -not $_.Enabled }
        $script:controls.ProfilesGrid.SelectedItem = $test
        $script:controls.NicknameBox.Text = '  Lab  '
        Invoke-Click $script:controls.RenameProfileButton
        $script:sent.Kind | Should -Be @('SetProfileNickname')
        $script:sent[0].Parameter.Aid | Should -Be $test.Aid
        $script:sent[0].Parameter.Nickname | Should -Be 'Lab'
    }

    It 'renames with an emoji, which SGP.22''s nickname takes' {
        Update-MainWindow -View $script:esimView
        $script:controls.ProfilesGrid.SelectedItem = @($script:controls.ProfilesGrid.ItemsSource)[0]
        $nickname = 'Travel ' + [char]::ConvertFromUtf32(0x1F1EE) + [char]::ConvertFromUtf32(0x1F1F9)
        $script:controls.NicknameBox.Text = $nickname
        Invoke-Click $script:controls.RenameProfileButton
        $script:sent.Kind | Should -Be @('SetProfileNickname')
        $script:sent[0].Parameter.Nickname | Should -Be $nickname
    }
    It 'refuses a nickname longer than 64 bytes, and says why' {
        Update-MainWindow -View $script:esimView
        $script:controls.ProfilesGrid.SelectedItem = @($script:controls.ProfilesGrid.ItemsSource)[0]
        $script:controls.NicknameBox.Text = 'è' * 33
        Invoke-Click $script:controls.RenameProfileButton
        $script:sent | Should -BeNullOrEmpty
        $script:controls.EsimHintText.Text | Should -Match '64 bytes'
        $script:controls.EsimHintText.Visibility | Should -Be 'Visible'
    }

    It 'keeps the selection when the list is filled again' {
        Update-MainWindow -View $script:esimView
        $test = @($script:controls.ProfilesGrid.ItemsSource) | Where-Object { -not $_.Enabled }
        $script:controls.ProfilesGrid.SelectedItem = $test
        $renamed = Copy-EsimView -View $script:esimView -Change @{ Profiles = [object[]]@($script:esimView.Esim.Profiles | ForEach-Object { $row = $_ | Select-Object -Property *; if (-not $row.Enabled) { $row.Nickname = 'Lab'; $row.Name = 'Lab' }; $row }) }
        Update-MainWindow -View $renamed
        $script:controls.ProfilesGrid.SelectedItem.Aid | Should -Be $test.Aid
        $script:controls.NicknameBox.Text | Should -Be 'Lab'
    }

    It 'asks for a code first, and sends nothing without one' {
        Update-MainWindow -View $script:emptyView
        Invoke-Click $script:controls.DownloadProfileButton
        $script:sent | Should -BeNullOrEmpty
        $script:controls.EsimHintText.Text | Should -Be 'Type or paste the activation code, or choose the image of its QR code, first.'
    }

    It 'downloads from the code typed, with its confirmation code, and empties the form once done' {
        Update-MainWindow -View $script:emptyView
        $script:controls.ActivationCodeBox.Password = 'LPA:1$smdp.example.com$SECRET-MATCH-3'
        $script:controls.ConfirmationCodeBox.Password = '1234'
        Invoke-Click $script:controls.DownloadProfileButton
        $script:sent.Kind | Should -Be @('DownloadProfile')
        $script:sent[0].Parameter.ActivationCode | Should -BeOfType ([securestring])
        Get-Plain $script:sent[0].Parameter.ActivationCode | Should -Be 'LPA:1$smdp.example.com$SECRET-MATCH-3'
        Get-Plain $script:sent[0].Parameter.ConfirmationCode | Should -Be '1234'
        $script:sent[0].Parameter.ContainsKey('QrImage') | Should -BeFalse
        $script:controls.ActivationCodeBox.Password | Should -Not -BeNullOrEmpty -Because 'the download has not answered yet'

        Update-MainWindow -View (Add-ViewResult -View $script:emptyView -Id 'id-1' -Kind 'DownloadProfile' -Result 'Done')
        $script:controls.ActivationCodeBox.Password | Should -Be ''
        $script:controls.ConfirmationCodeBox.Password | Should -Be ''
    }

    It 'downloads from the image of a QR code chosen, which a code typed replaces' {
        Update-MainWindow -View (Copy-EsimView -View $script:emptyView -Change @{ CanReadQr = $true })
        $script:controls.ReadQrButton.IsEnabled | Should -BeTrue
        $script:controls.ActivationCodeBox.Password = 'typed'
        $script:image = Join-Path $TestDrive 'code.png'
        Invoke-Click $script:controls.ReadQrButton
        $script:controls.ActivationCodeBox.Password | Should -Be '' -Because 'the image takes the place of the code typed'
        $script:controls.QrImageText.Text | Should -Be 'QR code image: code.png. Its code is read when the download starts.'
        Invoke-Click $script:controls.DownloadProfileButton
        $script:sent.Kind | Should -Be @('DownloadProfile')
        $script:sent[0].Parameter.QrImage | Should -Be $script:image
        $script:sent[0].Parameter.ContainsKey('ActivationCode') | Should -BeFalse

        Update-MainWindow -View (Add-ViewResult -View $script:emptyView -Id 'id-1' -Kind 'DownloadProfile' -Result 'NoQrCode')
        $script:controls.ActivationCodeBox.Password = 'LPA:1$smdp.example.com$ABC'
        $script:controls.QrImageText.Visibility | Should -Be 'Collapsed' -Because 'a code typed replaces the image'
        Invoke-Click $script:controls.DownloadProfileButton
        $script:sent[1].Parameter.ContainsKey('QrImage') | Should -BeFalse
    }

    It 'can''t read a QR code where ZXing.Net is missing, and says why' {
        Update-MainWindow -View (Copy-EsimView -View $script:emptyView -Change @{ CanReadQr = $false; QrNote = 'not here' })
        $script:controls.ReadQrButton.IsEnabled | Should -BeFalse
        $script:controls.ReadQrButton.ToolTip | Should -Be 'not here'
    }

    It 'sends one eSIM command at a time: the tab waits for its outcome' {
        Update-MainWindow -View $script:emptyView
        $script:controls.ProfilesGrid.SelectedItem = @($script:controls.ProfilesGrid.ItemsSource)[0]
        Invoke-Click $script:controls.ReadEsimButton
        $script:sent.Kind | Should -Be @('ReadEsim')
        foreach ($button in 'ReadEsimButton', 'UsePhysicalButton', 'EnableProfileButton', 'DeleteProfileButton', 'RenameProfileButton', 'DownloadProfileButton') {
            $script:controls.$button.IsEnabled | Should -BeFalse -Because "$button waits"
        }
        Update-MainWindow -View $script:emptyView
        $script:controls.ReadEsimButton.IsEnabled | Should -BeFalse -Because 'the worker has not answered yet'
        Update-MainWindow -View (Add-ViewResult -View $script:emptyView -Id 'id-1' -Kind 'ReadEsim' -Result 'Done')
        $script:controls.ReadEsimButton.IsEnabled | Should -BeTrue
        $script:controls.EnableProfileButton.IsEnabled | Should -BeTrue
    }

    It 'can act again once another worker took over: the command went with the one that ended' {
        Update-MainWindow -View $script:emptyView
        Invoke-Click $script:controls.ReadEsimButton
        Update-MainWindow -View (Copy-EsimView -View $script:emptyView -Change @{ Generation = [int]$script:emptyView.Esim.Generation + 1 })
        $script:controls.ReadEsimButton.IsEnabled | Should -BeTrue
    }

    It 'asks for the name typed in its own dialog: its button works once it matches, blanks and case aside' {
        $dialog = & (Get-Module FibocomFm350.App) { New-WindowTypedNameDialog -Title 'Delete' -Message 'Type it.' -Name 'Lab test profile' }
        try {
            $dialog.Button.IsEnabled | Should -BeFalse
            $dialog.Box.Text = 'Lab test'
            $dialog.Button.IsEnabled | Should -BeFalse
            $dialog.Box.Text = ' lab TEST profile '
            $dialog.Button.IsEnabled | Should -BeTrue
            $dialog.Box.Text = 'Lab test profile 2'
            $dialog.Button.IsEnabled | Should -BeFalse
            $dialog.Window.Title | Should -Be 'Delete'
        }
        finally {
            $dialog.Window.Close()
        }
    }

    It 'copies the EID, or says it could not: another program may hold the clipboard' {
        Update-MainWindow -View $script:emptyView
        $script:clipboardBusy = $true
        { Invoke-Click $script:controls.CopyEidButton } | Should -Not -Throw
        $script:controls.EsimHintText.Text | Should -Be 'The EID could not be copied: select it and copy it with Ctrl+C.'
        $script:clipboardBusy = $false
        Invoke-Click $script:controls.CopyEidButton
        $script:copied | Should -Be $script:emptyView.Esim.Eid
        $script:controls.EsimHintText.Visibility | Should -Be 'Collapsed'
    }
}
