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
    'ApnBox', 'PdpTypeBox', 'AuthenticationBox', 'ApnUserBox', 'ApnPasswordBox', 'ClearPasswordBox', 'ApnPasswordStoredText'
    'DnsBox', 'MetricBox', 'SaveSettingsButton', 'ReloadSettingsButton', 'SettingsProblemText'
)

# What the confirmations say: they guard the two actions that change something outside the app.
$script:UnlockConfirmation = @'
Unlock the modem?

This writes the modem's non-volatile memory and lifts a restriction that the laptop's maker set for its radio certification. It is done at your own responsibility, and it may not work on every module.

The modem restarts afterwards.
'@
$script:DisablePinConfirmation = @'
Remove the PIN from the SIM?

This changes the SIM card, not the app: the SIM will no longer ask for its PIN, in this modem or in any phone. A wrong PIN uses up one of its attempts.
'@

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
        Closing the window hides it: the app stays in the tray.

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

        [scriptblock] $Ask
    )

    $window = [System.Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath 'MainWindow.xaml') -Raw))
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
    $script:MainWindow = @{
        Window       = $window
        Controls     = $controls
        Send         = $Send
        Ask          = $Ask
        View         = $null
        # The settings the form was last filled with, and the newest command outcome seen.
        FormSettings = $null
        LastResultId = $null
        # A hint on the SIM tab, until the next PIN action.
        SimHint      = $null
        Exiting      = $false
    }

    $window.Add_Closing({
            param($source, $closing)
            if (-not $script:MainWindow.Exiting) {
                $closing.Cancel = $true
                $source.Hide()
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
                $script:MainWindow.SimHint = 'Type the SIM''s PIN first: removing it needs the PIN.'
            }
            elseif (& $script:MainWindow.Ask 'Remove the PIN from the SIM' $script:DisablePinConfirmation) {
                & $script:MainWindow.Send 'DisableSimPin' @{ Pin = $box.SecurePassword }
                $box.Clear()
            }
            if ($script:MainWindow.View) {
                Update-MainWindow -View $script:MainWindow.View
            }
        })
    $controls.SaveSettingsButton.Add_Click({ Save-WindowSetting })
    $controls.ReloadSettingsButton.Add_Click({
            $script:MainWindow.FormSettings = $null
            if ($script:MainWindow.View) {
                Update-MainWindow -View $script:MainWindow.View
            }
        })
    $script:MainWindow
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
            if (& $script:MainWindow.Ask 'Unlock the modem' $script:UnlockConfirmation) {
                & $script:MainWindow.Send 'UnlockFcc' @{}
            }
        }
    }
}

function Get-WindowSetting {
    # The settings as the connection tab's form has them, not validated.
    $controls = $script:MainWindow.Controls
    [ordered]@{
        Apn               = $controls.ApnBox.Text.Trim()
        PdpType           = [string]$controls.PdpTypeBox.SelectedItem.Content
        ApnAuthentication = [string]$controls.AuthenticationBox.SelectedItem.Content
        ApnUser           = $controls.ApnUserBox.Text
        DnsServers        = [string[]]@($controls.DnsBox.Text -split '[,;\s]+' | Where-Object { $_ })
        InterfaceMetric   = $controls.MetricBox.Text.Trim()
    }
}

function Save-WindowSetting {
    # The connection tab's Save: checked here, so a typo is shown at once, then sent.
    $controls = $script:MainWindow.Controls
    $checked = ConvertTo-AppSetting -InputObject (Get-WindowSetting)
    if ($checked.Problems.Count -gt 0) {
        $controls.SettingsProblemText.Text = $checked.Problems -join ' '
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
    $controls.ApnPasswordBox.Clear()
    $controls.ClearPasswordBox.IsChecked = $false
    # Filled again from the snapshot once the worker has saved them.
    $script:MainWindow.FormSettings = $null
}

function Select-ComboBoxItem {
    # Selects the item whose text is $Text.
    param([object] $ComboBox, [string] $Text)

    foreach ($item in $ComboBox.Items) {
        if ([string]$item.Content -eq $Text) {
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
    $controls.SignalText.Text = if ($View.Signal.Count -gt 0) { $View.Signal -join [Environment]::NewLine } else { 'Nothing measured.' }
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

    $controls.ApnPasswordStoredText.Text = if ($View.ApnPasswordStored) { 'A password is stored.' } else { 'No password is stored.' }
    # The form is filled again after a save the worker carried out.
    $newest = $View.LastResult
    if ($newest -and $newest.Id -ne $script:MainWindow.LastResultId) {
        $script:MainWindow.LastResultId = $newest.Id
        if ($newest.Kind -eq 'SaveSettings') {
            $script:MainWindow.FormSettings = $null
        }
    }
    if ($View.Settings -and $null -eq $script:MainWindow.FormSettings) {
        $settings = $View.Settings
        $controls.ApnBox.Text = $settings.Apn
        Select-ComboBoxItem -ComboBox $controls.PdpTypeBox -Text $settings.PdpType
        Select-ComboBoxItem -ComboBox $controls.AuthenticationBox -Text $settings.ApnAuthentication
        $controls.ApnUserBox.Text = $settings.ApnUser
        $controls.DnsBox.Text = @($settings.DnsServers) -join ', '
        $controls.MetricBox.Text = [string]$settings.InterfaceMetric
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
