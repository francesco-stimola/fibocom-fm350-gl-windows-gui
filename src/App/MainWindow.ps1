# The main window: loaded from MainWindow.xaml, filled from ConvertTo-WindowView, its buttons turned
# into commands for the worker. Nothing here waits on the modem or the system: a button queues a
# command and returns, and the outcome comes back in a later snapshot (ARCHITECTURE -> Invariants).

# The controls the code reaches by name; New-MainWindow fails at once if the XAML lacks one.
$script:WindowControlNames = @(
    'ToneDot', 'TitleText', 'TechnologyText', 'OperatorText', 'DetailText', 'NoteText'
    'BlockerPanel', 'BlockerText', 'BlockerInput', 'BlockerSecret', 'BlockerButton'
    'ResultText', 'FooterText', 'CheckNowButton'
    'SignalText', 'CellsGrid', 'CarriersGrid'
    'SimStateText', 'SimRequestText', 'SimStoredText', 'SimNoteText', 'SimPinBox', 'StorePinButton', 'ForgetPinButton', 'DisablePinButton'
    'CurrentModeText', 'NetworkModeBox', 'BandsPanel', 'LteAllBox', 'LteBandsPanel', 'NrAllBox', 'NrBandsPanel', 'ModeNoteText', 'ApplyModeButton', 'ReloadModeButton'
    'ApnBox', 'PdpTypeBox', 'AuthenticationBox', 'ApnUserBox', 'ApnPasswordBox', 'ClearPasswordBox', 'ApnPasswordStoredText'
    'DnsBox', 'DohBox', 'DohTemplateBox', 'DohRefreshBox', 'DohStateText', 'MetricBox', 'UpdateCheckBox', 'StartupBox', 'StartupNoteText', 'SaveSettingsButton', 'ReloadSettingsButton', 'SettingsProblemText'
    'Tabs', 'ConnectionTab', 'DriverTab', 'DriverStateText', 'DriverSourceText', 'OpenDriverPageButton', 'ChooseDriverButton', 'DriverPackageText'
    'InstallDriverButton', 'UninstallDriverButton', 'DriverNoteText'
    'MessagesTab', 'MessagesStateText', 'MessagesGrid', 'MessageHeaderText', 'DeleteMessageButton', 'MessageBodyText', 'MessageNoteText'
    'MessageToBox', 'MessageTextBox', 'MessageCountText', 'SendMessageButton'
    'DataTab', 'UsageTodayText', 'UsageCycleText', 'UsageQuotaText', 'UsageQuotaBar', 'CycleDayBox', 'QuotaBox', 'SaveUsageButton', 'ReloadUsageButton', 'UsageProblemText'
)

# The quota bar's colours: below the first threshold, and from it on.
$script:UsageBarColors = @{ Normal = '#2E7D32'; Warning = '#C0392B' }

# The main window and what it remembers; one per app. Event handlers reach it here.
$script:MainWindow = $null

function New-MainWindow {
    <#
    .SYNOPSIS
        Loads the main window and wires its buttons.
    .DESCRIPTION
        -Send queues a command for the worker: it is called with a command kind and its
        parameters (Send-ModemCommand's), and must not wait. -Ask asks the user a question
        and returns $true when they agree; a modal Yes/No dialog by default, No preselected.
        -Choose asks for a driver package and returns its path, or nothing; a file dialog by
        default (a zip, or an INF in its folder). -Open shows a web page; by default Explorer
        hands it to the user's browser - the app runs elevated, and should never start a browser
        itself. Closing the window hides it: the app stays in the tray. -AppUserModelId is the
        window's identity on the taskbar (AppIdentity.ps1); the app's by default.

        Returns a hashtable: Window, Controls (by name), View (the last one shown) and what the
        handlers need.
    .EXAMPLE
        $window = New-MainWindow -Send { param($kind, $parameter) Send-ModemCommand -Link $link -Kind $kind -Parameter $parameter }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory window; changes no system state.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Send,

        [scriptblock] $Ask,

        [scriptblock] $Choose,

        [scriptblock] $Open,

        [string] $AppUserModelId = $script:AppUserModelId
    )

    $xaml = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'MainWindow.xaml') -Raw
    $window = [System.Windows.Markup.XamlReader]::Parse((ConvertTo-LocalizedXaml -Xaml $xaml))
    # The app's icon, in the title bar and on the taskbar - as the app's, not its PowerShell's.
    $window.Icon = New-AppIconImage
    try {
        Set-AppWindowIdentity -Window $window -Id $AppUserModelId
    }
    catch {
        # The window works without: the taskbar then shows the PowerShell that hosts it.
        Write-Verbose "The window's taskbar identity can't be set: $($_.Exception.Message)"
    }
    $controls = @{}
    foreach ($name in $script:WindowControlNames) {
        $control = $window.FindName($name)
        if (-not $control) {
            throw [System.InvalidOperationException]::new("MainWindow.xaml has no control named '$name'.")
        }
        $controls[$name] = $control
    }
    if (-not $Ask) {
        $Ask = {
            param($title, $message)
            [System.Windows.MessageBox]::Show($script:MainWindow.Window, $message, $title, 'YesNo', 'Warning', 'No') -eq 'Yes'
        }
    }
    if (-not $Choose) {
        $Choose = {
            $dialog = [Microsoft.Win32.OpenFileDialog]::new()
            $dialog.Title = Get-AppText 'Driver.ChooseTitle'
            $dialog.Filter = "$(Get-AppText 'Driver.FileKind') (*.zip, *.inf)|*.zip;*.inf"
            if ($dialog.ShowDialog($script:MainWindow.Window)) {
                $dialog.FileName
            }
        }
    }
    if (-not $Open) {
        $Open = {
            param($url)
            # Explorer from the Windows folder, never found through PATH (ARCHITECTURE ->
            # Invariants): it hands the page to the browser of the user's own session.
            Start-Process -FilePath (Join-Path -Path ([Environment]::GetFolderPath('Windows')) -ChildPath 'explorer.exe') -ArgumentList $url
        }
    }
    $script:MainWindow = @{
        Window       = $window
        Controls     = $controls
        Send         = $Send
        Ask          = $Ask
        Choose       = $Choose
        Open         = $Open
        View         = $null
        # The settings the form was last filled with, and the newest command outcome seen.
        FormSettings = $null
        LastResultId = $null
        # A hint on the SIM tab, until the next PIN action.
        SimHint      = $null
        # The network tab: the choices and bands its controls were built for, the selection the
        # form was last filled with, and a hint until the next apply.
        ModeChoices  = $null
        ModeBands    = $null
        ModeRevision = $null
        FormMode     = $null
        ModeHint     = $null
        # The Data tab's form, as last filled from the settings.
        FormUsage    = $null
        # The Messages tab: the list as last shown, the message the user selected, the newest
        # message sent and the text it had; and whether the window is filling the list itself,
        # so a selection it restores opens nothing.
        MessagesShown = $null
        SelectedKey   = $null
        SentId        = $null
        SentText      = $null
        # A message sent and not answered yet: its command's Id and the worker that has it.
        SendPending   = $null
        Updating      = $false
        Exiting      = $false
    }

    $window.Add_Closing({
            param($source, $closing)
            if (-not $script:MainWindow.Exiting) {
                $closing.Cancel = $true
                $source.Hide()
            }
            else {
                # A window's properties are taken off before it closes, or Windows keeps them. A
                # handler that throws would end the app.
                try {
                    Set-AppWindowIdentity -Window $source -Remove
                }
                catch {
                    Write-Verbose "The window's taskbar identity can't be removed: $($_.Exception.Message)"
                }
            }
        })
    $controls.CheckNowButton.Add_Click({ & $script:MainWindow.Send 'ConnectNow' @{} })
    $controls.BlockerButton.Add_Click({ Invoke-BlockerAction })
    $controls.StorePinButton.Add_Click({
            $box = $script:MainWindow.Controls.SimPinBox
            $script:MainWindow.SimHint = $null
            if ($box.SecurePassword.Length -gt 0) {
                & $script:MainWindow.Send 'SaveSimPin' @{ Pin = $box.SecurePassword }
                $box.Clear()
            }
        })
    $controls.ForgetPinButton.Add_Click({ & $script:MainWindow.Send 'ForgetSimPin' @{} })
    $controls.DisablePinButton.Add_Click({
            $box = $script:MainWindow.Controls.SimPinBox
            $script:MainWindow.SimHint = $null
            if ($box.SecurePassword.Length -eq 0) {
                $script:MainWindow.SimHint = Get-AppText 'Window.PinFirst'
            }
            elseif (& $script:MainWindow.Ask (Get-AppText 'Confirm.DisablePinTitle') (Get-AppText 'Confirm.DisablePin')) {
                & $script:MainWindow.Send 'DisableSimPin' @{ Pin = $box.SecurePassword }
                $box.Clear()
            }
            if ($script:MainWindow.View) {
                Update-MainWindow -View $script:MainWindow.View
            }
        })
    $controls.ApplyModeButton.Add_Click({ Send-WindowNetworkMode })
    $controls.ReloadModeButton.Add_Click({
            $script:MainWindow.FormMode = $null
            $script:MainWindow.ModeHint = $null
            if ($script:MainWindow.View) {
                Update-MainWindow -View $script:MainWindow.View
            }
        })
    $controls.NetworkModeBox.Add_SelectionChanged({ Sync-WindowBandState })
    $controls.LteAllBox.Add_Click({ Sync-WindowBandState })
    $controls.NrAllBox.Add_Click({ Sync-WindowBandState })
    $controls.OpenDriverPageButton.Add_Click({
            $driver = if ($script:MainWindow.View) { $script:MainWindow.View.Driver } else { $null }
            if ($driver -and $driver.PageUrl) {
                & $script:MainWindow.Open $driver.PageUrl
            }
        })
    $controls.ChooseDriverButton.Add_Click({
            $path = & $script:MainWindow.Choose
            if ($path) {
                & $script:MainWindow.Send 'CheckDriverPackage' @{ Path = [string]$path }
            }
        })
    $controls.InstallDriverButton.Add_Click({ Invoke-WindowDriverInstall })
    $controls.UninstallDriverButton.Add_Click({
            if (& $script:MainWindow.Ask (Get-AppText 'Confirm.UninstallDriverTitle') (Get-AppText 'Confirm.UninstallDriver')) {
                & $script:MainWindow.Send 'UninstallDriver' @{}
            }
        })
    $controls.SaveSettingsButton.Add_Click({ Save-WindowSetting })
    $controls.ReloadSettingsButton.Add_Click({
            $script:MainWindow.FormSettings = $null
            if ($script:MainWindow.View) {
                Update-MainWindow -View $script:MainWindow.View
            }
        })
    $controls.MessagesGrid.Add_SelectionChanged({ Select-WindowMessage })
    $controls.DeleteMessageButton.Add_Click({ Invoke-WindowMessageDelete })
    $controls.SendMessageButton.Add_Click({ Send-WindowMessage })
    $controls.MessageTextBox.Add_TextChanged({ Show-WindowMessageCount })
    $controls.SaveUsageButton.Add_Click({ Save-WindowUsageSetting })
    $controls.ReloadUsageButton.Add_Click({
            $script:MainWindow.FormUsage = $null
            if ($script:MainWindow.View) {
                Update-MainWindow -View $script:MainWindow.View
            }
        })
    $script:MainWindow
}

function Show-WindowMessage {
    # The selected message below the list - its sender and time, its text, a note - and whether it
    # can be deleted.
    param([object] $Message)

    $controls = $script:MainWindow.Controls
    $view = $script:MainWindow.View
    $controls.MessageHeaderText.Text = if ($Message) { $Message.Header } else { '' }
    $controls.MessageBodyText.Text = if ($Message) { $Message.Text } else { '' }
    $note = if ($Message) { $Message.Note } else { $null }
    $controls.MessageNoteText.Text = [string]$note
    $controls.MessageNoteText.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
    $controls.DeleteMessageButton.IsEnabled = [bool]($Message -and $view -and $view.Messages -and $view.Messages.CanDelete)
}

function Select-WindowMessage {
    # A message the user selected in the list: shown, and opened - new no more (decided
    # 2026-10-04). A selection the window restores after a refresh opens nothing; one the user
    # makes again opens it again, in case the command was lost with a worker that ended.
    $message = $script:MainWindow.Controls.MessagesGrid.SelectedItem
    Show-WindowMessage -Message $message
    if ($script:MainWindow.Updating -or -not $message) {
        return
    }
    $script:MainWindow.SelectedKey = $message.Key
    if ($message.New) {
        [void](& $script:MainWindow.Send 'OpenMessage' @{ Fingerprints = [string[]]$message.Fingerprints })
    }
}

function Invoke-WindowMessageDelete {
    # The Delete button: the selected message, every part of it, once the user confirmed it - No
    # preselected (decided 2026-10-04).
    $message = $script:MainWindow.Controls.MessagesGrid.SelectedItem
    if ($message -and (& $script:MainWindow.Ask (Get-AppText 'Confirm.DeleteMessageTitle') (Get-AppText 'Confirm.DeleteMessage'))) {
        & $script:MainWindow.Send 'DeleteMessage' @{ Fingerprints = [string[]]$message.Fingerprints }
    }
}

function Send-WindowMessage {
    # The Send button: the number and the text as typed, for the worker, which checks them. The
    # text stays until the message is sent: one that fails, the user may send again. Once queued
    # the button waits for the worker's answer - a second click, or a double one, sends nothing.
    $controls = $script:MainWindow.Controls
    if ($script:MainWindow.SendPending) {
        return
    }
    $number = $controls.MessageToBox.Text.Trim()
    $text = $controls.MessageTextBox.Text
    if (-not $number -or -not $text) {
        $controls.MessageCountText.Text = Get-AppText 'Result.SendMessage.Invalid'
        return
    }
    $script:MainWindow.SentText = $text
    $id = & $script:MainWindow.Send 'SendMessage' @{ Number = $number; Text = $text }
    if ($id) {
        $view = $script:MainWindow.View
        $script:MainWindow.SendPending = @{ Id = [string]$id; Generation = $(if ($view -and $view.Messages) { $view.Messages.Generation }) }
        $controls.SendMessageButton.IsEnabled = $false
    }
}

function Show-WindowMessageCount {
    # The characters and parts of the message being written, as it is typed - unless one is
    # going out.
    $controls = $script:MainWindow.Controls
    $view = $script:MainWindow.View
    if ($view -and $view.Messages -and $view.Messages.SendingText) {
        $controls.MessageCountText.Text = $view.Messages.SendingText
    }
    else {
        $controls.MessageCountText.Text = [string](Get-MessageCountText -Text $controls.MessageTextBox.Text)
    }
}

function Show-WindowMessageList {
    # The Messages tab, from the view. The list is filled again only when it changed, and the
    # user's selection kept; the text being written is cleared once it is sent.
    param([object] $View)

    $controls = $script:MainWindow.Controls
    $messages = $View.Messages
    $controls.MessagesTab.Header = $messages.TabText
    $controls.MessagesStateText.Text = [string]$messages.StateText
    $signature = @($messages.Items | ForEach-Object { "$($_.Key)|$($_.New)" }) -join ';'
    if ($signature -ne $script:MainWindow.MessagesShown) {
        $script:MainWindow.Updating = $true
        try {
            $controls.MessagesGrid.ItemsSource = $messages.Items
            $controls.MessagesGrid.SelectedItem = @($messages.Items | Where-Object { $_.Key -eq $script:MainWindow.SelectedKey }) | Select-Object -First 1
        }
        finally {
            $script:MainWindow.Updating = $false
        }
        $script:MainWindow.MessagesShown = $signature
    }
    Show-WindowMessage -Message $controls.MessagesGrid.SelectedItem
    # A message waiting for its answer: until the worker has answered it, or another worker took
    # over - the command went with the one that ended.
    $pending = $script:MainWindow.SendPending
    if ($pending -and ($pending.Id -in @($messages.SendIds) -or $messages.Generation -ne $pending.Generation)) {
        $script:MainWindow.SendPending = $null
    }
    $controls.SendMessageButton.IsEnabled = $messages.CanSend -and -not $script:MainWindow.SendPending
    if ($messages.SentId -and $messages.SentId -ne $script:MainWindow.SentId) {
        $script:MainWindow.SentId = $messages.SentId
        if ($controls.MessageTextBox.Text -eq $script:MainWindow.SentText) {
            $controls.MessageTextBox.Clear()
        }
    }
    Show-WindowMessageCount
}

function Show-WindowUsage {
    # The Data tab, from the view. Its form is filled from the settings only when it was never
    # filled, after Undo, and after a save.
    param([object] $View)

    $controls = $script:MainWindow.Controls
    $usage = $View.Usage
    $controls.UsageTodayText.Text = [string]$usage.TodayText
    $controls.UsageCycleText.Text = [string]$usage.CycleText
    $controls.UsageCycleText.Visibility = if ($usage.CycleText) { 'Visible' } else { 'Collapsed' }
    $controls.UsageQuotaText.Text = [string]$usage.QuotaText
    $controls.UsageQuotaText.Visibility = if ($usage.QuotaText) { 'Visible' } else { 'Collapsed' }
    $controls.UsageQuotaBar.Visibility = if ($null -ne $usage.Percent) { 'Visible' } else { 'Collapsed' }
    $controls.UsageQuotaBar.Value = if ($null -ne $usage.Percent) { $usage.Percent } else { 0 }
    $color = $script:UsageBarColors[$(if ($usage.Warning) { 'Warning' } else { 'Normal' })]
    $controls.UsageQuotaBar.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
    $settings = $View.Settings
    if ($settings -and $settings.PSObject.Properties['UsageCycleDay'] -and $null -eq $script:MainWindow.FormUsage) {
        $controls.CycleDayBox.Text = [string]$settings.UsageCycleDay
        $controls.QuotaBox.Text = ([double]$settings.UsageQuotaGB).ToString('0.###', [cultureinfo]::InvariantCulture)
        $controls.UsageProblemText.Text = ''
        $script:MainWindow.FormUsage = $settings
    }
}

function Join-WindowSetting {
    # The settings one tab saves: those saved, with the values its form has. The other tab's
    # settings stay as saved, whatever is typed there.
    param([object] $Saved, [System.Collections.IDictionary] $Form)

    $settings = [ordered]@{}
    if ($Saved) {
        foreach ($property in $Saved.PSObject.Properties) {
            $settings[$property.Name] = $property.Value
        }
    }
    foreach ($key in $Form.Keys) {
        $settings[$key] = $Form[$key]
    }
    $settings
}

function Save-WindowUsageSetting {
    # The Data tab's Save: the cycle's first day and the quota as typed - a decimal comma read as
    # a point -, checked here so a typo shows at once, then sent with the other settings as saved.
    $controls = $script:MainWindow.Controls
    $saved = if ($script:MainWindow.View) { $script:MainWindow.View.Settings } else { $null }
    $form = [ordered]@{ UsageCycleDay = $controls.CycleDayBox.Text.Trim(); UsageQuotaGB = $controls.QuotaBox.Text.Trim().Replace(',', '.') }
    $checked = ConvertTo-AppSetting -InputObject (Join-WindowSetting -Saved $saved -Form $form)
    $problems = @($checked.Issues | Where-Object { $_.Setting -in $form.Keys } | ForEach-Object { ConvertTo-SettingIssueText -Issue $_ })
    if ($problems.Count -gt 0) {
        $controls.UsageProblemText.Text = $problems -join ' '
        return
    }
    $controls.UsageProblemText.Text = ''
    & $script:MainWindow.Send 'SaveSettings' @{ Settings = $checked.Settings }
    # Filled again from the snapshot once the worker has saved them.
    $script:MainWindow.FormUsage = $null
}

function Invoke-BlockerAction {
    # The blocker panel's button: the action that unblocks the connection.
    $view = $script:MainWindow.View
    $controls = $script:MainWindow.Controls
    if (-not $view -or -not $view.Blocker) {
        return
    }
    switch ($view.Blocker.Kind) {
        'Apn' {
            $settings = $view.Settings | Select-Object -Property *
            $settings.Apn = $controls.BlockerInput.Text.Trim()
            if ($settings.Apn) {
                & $script:MainWindow.Send 'SaveSettings' @{ Settings = $settings }
            }
        }
        'ApnPassword' {
            if ($controls.BlockerSecret.SecurePassword.Length -gt 0) {
                & $script:MainWindow.Send 'SaveSettings' @{ Settings = $view.Settings; ApnPassword = $controls.BlockerSecret.SecurePassword }
                $controls.BlockerSecret.Clear()
            }
        }
        'Pin' {
            if ($controls.BlockerSecret.SecurePassword.Length -gt 0) {
                & $script:MainWindow.Send 'SaveSimPin' @{ Pin = $controls.BlockerSecret.SecurePassword }
                $controls.BlockerSecret.Clear()
            }
        }
        'EnableAdapter' {
            & $script:MainWindow.Send 'EnableAdapter' @{}
        }
        'Unlock' {
            if (& $script:MainWindow.Ask (Get-AppText 'Confirm.UnlockTitle') (Get-AppText 'Confirm.Unlock')) {
                & $script:MainWindow.Send 'UnlockFcc' @{}
            }
        }
        'NetworkMode' {
            & $script:MainWindow.Send 'SetNetworkMode' @{ NetworkMode = 'Automatic'; LteBands = [int[]]@(); NrBands = [int[]]@() }
            $script:MainWindow.FormMode = $null
        }
        'Driver' {
            $controls.Tabs.SelectedItem = $controls.DriverTab
        }
        'Settings' {
            $controls.Tabs.SelectedItem = $controls.ConnectionTab
        }
    }
}

function Invoke-WindowDriverInstall {
    # The Driver tab's Install: a version the app knows at once; one it doesn't, once the user
    # accepted it.
    $driver = if ($script:MainWindow.View) { $script:MainWindow.View.Driver } else { $null }
    if (-not $driver -or -not $driver.CanInstall) {
        return
    }
    if (-not $driver.ConfirmInstall) {
        & $script:MainWindow.Send 'InstallDriver' @{}
    }
    elseif (& $script:MainWindow.Ask (Get-AppText 'Confirm.UnknownDriverTitle') (Get-AppText 'Confirm.UnknownDriver')) {
        & $script:MainWindow.Send 'InstallDriver' @{ AcceptUnknown = $true }
    }
}

function Get-WindowBandChoice {
    # The bands checked in one of the network tab's panels.
    param([object] $Panel)

    [int[]]@($Panel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [int]$_.Tag })
}

function Sync-WindowBandState {
    # The band checkboxes follow the form: only for a mode the app manages, for the RATs the mode
    # uses, and each band only when 'every band' is unchecked.
    $controls = $script:MainWindow.Controls
    $choice = $controls.NetworkModeBox.SelectedItem
    $mode = if ($choice) { [string]$choice.Name } else { '' }
    $controls.BandsPanel.IsEnabled = [bool]$mode
    foreach ($rat in @(@('Lte', 'NrOnly'), @('Nr', 'LteOnly'))) {
        $used = $mode -ne $rat[1]
        $controls["$($rat[0])AllBox"].IsEnabled = $used
        $controls["$($rat[0])BandsPanel"].IsEnabled = $used -and -not $controls["$($rat[0])AllBox"].IsChecked
    }
}

function Send-WindowNetworkMode {
    # The network tab's Apply: the mode and bands chosen, sent to the worker, which writes and
    # tries them. A RAT the mode uses needs a band at least.
    $controls = $script:MainWindow.Controls
    $choice = $controls.NetworkModeBox.SelectedItem
    if (-not $choice) {
        return
    }
    $mode = [string]$choice.Name
    $bands = @{}
    foreach ($rat in 'Lte', 'Nr') {
        $bands[$rat] = [int[]]@(if (-not $controls["${rat}AllBox"].IsChecked) { Get-WindowBandChoice -Panel $controls["${rat}BandsPanel"] })
    }
    $script:MainWindow.ModeHint = $null
    foreach ($rat in @(@('Lte', 'NrOnly', 'LTE'), @('Nr', 'LteOnly', 'NR'))) {
        if ($mode -and $mode -ne $rat[1] -and -not $controls["$($rat[0])AllBox"].IsChecked -and $bands[$rat[0]].Count -eq 0) {
            $script:MainWindow.ModeHint = Get-AppText 'Network.ChooseBand' $rat[2]
        }
    }
    if (-not $script:MainWindow.ModeHint) {
        & $script:MainWindow.Send 'SetNetworkMode' @{ NetworkMode = $mode; LteBands = $bands['Lte']; NrBands = $bands['Nr'] }
        # Filled again from the snapshot once the worker has it.
        $script:MainWindow.FormMode = $null
    }
    if ($script:MainWindow.View) {
        Update-MainWindow -View $script:MainWindow.View
    }
}

function Initialize-WindowBandPanel {
    # Fills a band panel with a checkbox per band the modem supports.
    param([object] $Panel, [int[]] $Band, [string] $Prefix)

    $Panel.Children.Clear()
    foreach ($number in $Band) {
        $box = [System.Windows.Controls.CheckBox]::new()
        $box.Content = "$Prefix$number"
        $box.Tag = $number
        $box.MinWidth = 56
        $box.Margin = [System.Windows.Thickness]::new(0, 0, 8, 4)
        [void]$Panel.Children.Add($box)
    }
}

function Show-WindowNetworkMode {
    # The network tab, from the view. The form is filled from the settings only when it was never
    # filled, after Undo, and after an apply, as the connection form is.
    param([object] $View)

    $controls = $script:MainWindow.Controls
    $mode = $View.NetworkMode
    $controls.CurrentModeText.Text = $mode.CurrentText
    $note = @($mode.Note, $script:MainWindow.ModeHint | Where-Object { $_ }) -join ' '
    $controls.ModeNoteText.Text = $note
    $controls.ModeNoteText.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
    $controls.ApplyModeButton.IsEnabled = $mode.CanApply

    $choices = @($mode.Modes | ForEach-Object Name) -join ','
    if ($choices -ne $script:MainWindow.ModeChoices) {
        $controls.NetworkModeBox.ItemsSource = $mode.Modes
        $script:MainWindow.ModeChoices = $choices
        $script:MainWindow.FormMode = $null
    }
    if ($mode.Revision -ne $script:MainWindow.ModeRevision) {
        $script:MainWindow.ModeRevision = $mode.Revision
        $script:MainWindow.FormMode = $null
    }
    $bands = "$($mode.Lte -join ',')/$($mode.Nr -join ',')"
    if ($bands -ne $script:MainWindow.ModeBands) {
        Initialize-WindowBandPanel -Panel $controls.LteBandsPanel -Band $mode.Lte -Prefix 'B'
        Initialize-WindowBandPanel -Panel $controls.NrBandsPanel -Band $mode.Nr -Prefix 'n'
        $script:MainWindow.ModeBands = $bands
        $script:MainWindow.FormMode = $null
    }
    if ($mode.Selection -and $null -eq $script:MainWindow.FormMode) {
        $selection = $mode.Selection
        $controls.NetworkModeBox.SelectedItem = @($controls.NetworkModeBox.Items | Where-Object { $_.Name -eq $selection.NetworkMode }) | Select-Object -First 1
        foreach ($rat in 'Lte', 'Nr') {
            $chosen = @($selection."${rat}Bands")
            $controls["${rat}AllBox"].IsChecked = $chosen.Count -eq 0
            foreach ($box in $controls["${rat}BandsPanel"].Children) {
                $box.IsChecked = $chosen.Count -eq 0 -or [int]$box.Tag -in $chosen
            }
        }
        $script:MainWindow.FormMode = $selection
    }
    Sync-WindowBandState
}

function Get-WindowSetting {
    # The settings as the connection tab's form has them, not validated.
    $controls = $script:MainWindow.Controls
    [ordered]@{
        Apn               = $controls.ApnBox.Text.Trim()
        PdpType           = [string]$controls.PdpTypeBox.SelectedItem.Tag
        ApnAuthentication = [string]$controls.AuthenticationBox.SelectedItem.Tag
        ApnUser           = $controls.ApnUserBox.Text
        DnsServers        = [string[]]@($controls.DnsBox.Text -split '[,;\s]+' | Where-Object { $_ })
        DnsOverHttps      = [bool]$controls.DohBox.IsChecked
        DohTemplate       = $controls.DohTemplateBox.Text.Trim()
        DohRefreshMinutes = $controls.DohRefreshBox.Text.Trim()
        InterfaceMetric   = $controls.MetricBox.Text.Trim()
        CheckForUpdates   = [bool]$controls.UpdateCheckBox.IsChecked
    }
}

function Test-WindowDohSetting {
    # What the worker would refuse to set, said before the save: encrypted DNS where Windows
    # can't set it, or a server with no template, known or given. Returns the problem, or $null.
    param([object] $Settings, [object] $Dns)

    if (-not $Settings.DnsOverHttps -or -not $Dns) {
        return $null
    }
    if (-not $Dns.CanEnable) {
        return Get-AppText 'Dns.NotAvailableHere'
    }
    if ($Settings.DohTemplate -or @($Dns.Known).Count -eq 0) {
        return $null
    }
    $unknown = @($Settings.DnsServers | Where-Object { $_ -notin $Dns.Known })
    if ($unknown.Count -gt 0) {
        return Get-AppText 'Dns.NoTemplate' ($unknown -join ', ')
    }
    $null
}

function Save-WindowSetting {
    # The connection tab's Save: checked here, so a typo is shown at once, then sent with the
    # other tabs' settings as saved.
    $controls = $script:MainWindow.Controls
    $saved = if ($script:MainWindow.View) { $script:MainWindow.View.Settings } else { $null }
    $checked = ConvertTo-AppSetting -InputObject (Join-WindowSetting -Saved $saved -Form (Get-WindowSetting))
    $dns = if ($script:MainWindow.View) { $script:MainWindow.View.Dns } else { $null }
    $problems = @($checked.Issues | ForEach-Object { ConvertTo-SettingIssueText -Issue $_ }) + @(Test-WindowDohSetting -Settings $checked.Settings -Dns $dns | Where-Object { $_ })
    if ($problems.Count -gt 0) {
        $controls.SettingsProblemText.Text = $problems -join ' '
        return
    }
    $controls.SettingsProblemText.Text = ''
    $parameter = @{ Settings = $checked.Settings }
    if ($controls.ClearPasswordBox.IsChecked) {
        $parameter['ApnPassword'] = [securestring]::new()
    }
    elseif ($controls.ApnPasswordBox.SecurePassword.Length -gt 0) {
        $parameter['ApnPassword'] = $controls.ApnPasswordBox.SecurePassword
    }
    & $script:MainWindow.Send 'SaveSettings' $parameter
    # The start at sign-in is the logon task's, not the settings file's: changed apart, when it
    # was.
    $startup = if ($script:MainWindow.View) { $script:MainWindow.View.Startup } else { $null }
    if ($startup -and $startup.CanChange -and [bool]$controls.StartupBox.IsChecked -ne [bool]$startup.Checked) {
        & $script:MainWindow.Send 'SetStartAtLogon' @{ Enabled = [bool]$controls.StartupBox.IsChecked }
    }
    $controls.ApnPasswordBox.Clear()
    $controls.ClearPasswordBox.IsChecked = $false
    # Filled again from the snapshot once the worker has saved them.
    $script:MainWindow.FormSettings = $null
}

function Select-ComboBoxItem {
    # Selects the item whose value - its Tag, never the text it shows in the app's language - is
    # $Text.
    param([object] $ComboBox, [string] $Text)

    foreach ($item in $ComboBox.Items) {
        if ([string]$item.Tag -eq $Text) {
            $ComboBox.SelectedItem = $item
        }
    }
}

function Update-MainWindow {
    <#
    .SYNOPSIS
        Shows a view (ConvertTo-WindowView) in the main window.
    .DESCRIPTION
        Fills every text and table from the view. What the user is typing is left alone: the
        connection form is filled from the settings only when it was never filled, after Undo,
        and after a save.
    .EXAMPLE
        Update-MainWindow -View (ConvertTo-WindowView -Snapshot $snapshot)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $View
    )

    if (-not $script:MainWindow -or -not $PSCmdlet.ShouldProcess('the main window', 'Update')) {
        return
    }
    $controls = $script:MainWindow.Controls
    $script:MainWindow.View = $View
    $show = { param($condition) if ($condition) { 'Visible' } else { 'Collapsed' } }

    $controls.ToneDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:ToneColors[$View.Tone])
    $controls.TitleText.Text = $View.Title
    $controls.TechnologyText.Text = [string]$View.Technology
    $controls.OperatorText.Text = [string]$View.Operator
    $controls.DetailText.Text = $View.Detail
    $controls.NoteText.Text = [string]$View.Note
    $controls.NoteText.Visibility = & $show $View.Note

    $blocker = $View.Blocker
    $controls.BlockerPanel.Visibility = & $show $blocker
    if ($blocker) {
        $controls.BlockerText.Text = $blocker.Message
        $controls.BlockerInput.Visibility = & $show ($blocker.Kind -eq 'Apn')
        $controls.BlockerSecret.Visibility = & $show ($blocker.Kind -in 'ApnPassword', 'Pin')
        $controls.BlockerButton.Visibility = & $show $blocker.Kind
        $controls.BlockerButton.Content = [string]$blocker.ActionText
        $controls.BlockerButton.IsEnabled = $blocker.Enabled
    }

    $controls.ResultText.Text = [string]$View.Result
    $controls.FooterText.Text = $View.Footer
    $controls.SignalText.Text = if ($View.Signal.Count -gt 0) { $View.Signal -join [Environment]::NewLine } else { Get-AppText 'Window.NothingMeasured' }
    $controls.CellsGrid.ItemsSource = $View.Cells
    $controls.CarriersGrid.ItemsSource = $View.Carriers

    $sim = $View.Sim
    if ($sim) {
        $controls.SimStateText.Text = $sim.StateText
        $controls.SimRequestText.Text = $sim.RequestText
        $controls.SimStoredText.Text = $sim.StoredText
        $note = @($sim.Note, $script:MainWindow.SimHint | Where-Object { $_ }) -join ' '
        $controls.SimNoteText.Text = $note
        $controls.SimNoteText.Visibility = & $show $note
        $controls.StorePinButton.IsEnabled = $sim.CanStorePin
        $controls.ForgetPinButton.IsEnabled = $sim.CanForgetPin
        $controls.DisablePinButton.IsEnabled = $sim.CanDisablePin
    }

    $driver = $View.Driver
    if ($driver) {
        $controls.DriverStateText.Text = $driver.StateText
        $controls.DriverSourceText.Text = $driver.SourceText
        $controls.OpenDriverPageButton.IsEnabled = [bool]$driver.PageUrl
        $controls.ChooseDriverButton.IsEnabled = $driver.CanChoose
        $controls.DriverPackageText.Text = [string]$driver.PackageText
        $controls.DriverPackageText.Visibility = & $show $driver.PackageText
        $controls.InstallDriverButton.IsEnabled = $driver.CanInstall
        $controls.InstallDriverButton.Content = Get-AppText $(if ($driver.ConfirmInstall) { 'Driver.InstallConfirm' } else { 'Driver.Install' })
        $controls.UninstallDriverButton.IsEnabled = $driver.CanUninstall
        $controls.DriverNoteText.Text = [string]$driver.Note
        $controls.DriverNoteText.Visibility = & $show $driver.Note
    }

    $controls.ApnPasswordStoredText.Text = Get-AppText $(if ($View.ApnPasswordStored) { 'Window.PasswordStored' } else { 'Window.NoPassword' })
    if ($View.Dns) {
        $controls.DohStateText.Text = [string]$View.Dns.Text
        $controls.DohStateText.Visibility = & $show $View.Dns.Text
        # Where Windows can't set it, it can only be turned off.
        $controls.DohBox.IsEnabled = $View.Dns.CanEnable -or [bool]$controls.DohBox.IsChecked
    }
    # The forms are filled again after a save the worker carried out.
    $newest = $View.LastResult
    if ($newest -and $newest.Id -ne $script:MainWindow.LastResultId) {
        $script:MainWindow.LastResultId = $newest.Id
        if ($newest.Kind -in 'SaveSettings', 'SetStartAtLogon') {
            $script:MainWindow.FormSettings = $null
            $script:MainWindow.FormUsage = $null
        }
        if ($newest.Kind -eq 'SetNetworkMode') {
            $script:MainWindow.FormMode = $null
        }
    }
    if ($View.NetworkMode) {
        Show-WindowNetworkMode -View $View
    }
    if ($View.PSObject.Properties['Messages'] -and $View.Messages) {
        Show-WindowMessageList -View $View
    }
    if ($View.PSObject.Properties['Usage'] -and $View.Usage) {
        Show-WindowUsage -View $View
    }
    if ($View.Startup) {
        $controls.StartupBox.IsEnabled = [bool]$View.Startup.CanChange
        $controls.StartupNoteText.Text = [string]$View.Startup.Note
        $controls.StartupNoteText.Visibility = if ($View.Startup.Note) { 'Visible' } else { 'Collapsed' }
    }
    if ($View.Settings -and $null -eq $script:MainWindow.FormSettings) {
        $settings = $View.Settings
        $controls.ApnBox.Text = $settings.Apn
        Select-ComboBoxItem -ComboBox $controls.PdpTypeBox -Text $settings.PdpType
        Select-ComboBoxItem -ComboBox $controls.AuthenticationBox -Text $settings.ApnAuthentication
        $controls.ApnUserBox.Text = $settings.ApnUser
        $controls.DnsBox.Text = @($settings.DnsServers) -join ', '
        $controls.DohBox.IsChecked = [bool]$settings.DnsOverHttps
        $controls.DohTemplateBox.Text = [string]$settings.DohTemplate
        $controls.DohRefreshBox.Text = [string]$settings.DohRefreshMinutes
        $controls.MetricBox.Text = [string]$settings.InterfaceMetric
        $controls.UpdateCheckBox.IsChecked = [bool]$settings.CheckForUpdates
        $controls.StartupBox.IsChecked = [bool]($View.Startup -and $View.Startup.Checked)
        $controls.SettingsProblemText.Text = ''
        $script:MainWindow.FormSettings = $settings
    }
}

function Show-MainWindow {
    <#
    .SYNOPSIS
        Brings the main window to the front, restored if it was minimized.
    .EXAMPLE
        Show-MainWindow
    #>
    [CmdletBinding()]
    param()

    $window = $script:MainWindow.Window
    $window.Show()
    if ($window.WindowState -eq 'Minimized') {
        $window.WindowState = 'Normal'
    }
    [void]$window.Activate()
}
