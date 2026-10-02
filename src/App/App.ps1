# The app: one process in the tray. The UI thread runs the tray icon, the main window and the
# supervisor, and never does I/O on the modem or the system; the worker owns the modem in a
# runspace of its own. Design: docs/ARCHITECTURE.md -> Process model.

# How often the UI thread looks at the worker: its latest snapshot, its heartbeat, the second
# launch's signal.
$script:UiTickMs = 500

# A gap this long between two ticks is a pause - the computer slept: the worker's silence is
# counted from the resume, never across the pause.
$script:UiPauseMs = 5000

# A worker silent this long is shown as not responding; the supervisor replaces it later
# (SupervisorTimings.HungMs).
$script:WorkerStaleMs = 15000

# How long exiting waits for the worker to close the AT port.
$script:ExitWaitMs = 5000

# The running app's state; one per process.
$script:App = $null

function Write-UiLog {
    # A line in the app's log from the UI thread: rare events only (start, restarts, exit).
    param([string] $Level, [string] $Message)

    try {
        Write-AppLog -Folder $script:App.LogFolder -Level $Level -Message $Message
    }
    catch {
        Write-Verbose "The log can't be written: $($_.Exception.Message)"
    }
}

function Start-AppWorker {
    # Starts the next worker; it attaches to the connection the last one left.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Start-WorkerRunspace, which it calls, supports ShouldProcess.')]
    param()

    $app = $script:App
    $app.Generation++
    try {
        $app.Worker = Start-WorkerRunspace -Generation $app.Generation -Worker $app.WorkerOptions -Previous $app.LastSnapshot -Confirm:$false
    }
    catch {
        $decision = Resolve-SupervisorAction -Ended -UptimeMs 0 -Failures $app.Failures
        $app.Failures = $decision.Failures
        $app.RestartAt = [Environment]::TickCount64 + $decision.DelayMs
        Write-UiLog -Level 'Error' -Message "Worker $($app.Generation) could not start: $($_.Exception.Message)"
    }
}

function Send-AppCommand {
    # Queues a command for the current worker; never waits.
    param([string] $Kind, [hashtable] $Parameter = @{})

    $worker = $script:App.Worker
    if ($worker) {
        [void](Send-ModemCommand -Link $worker.Link -Kind $Kind -Parameter $Parameter)
    }
    elseif ($script:MainWindow) {
        $script:MainWindow.Controls.ResultText.Text = 'The monitor is restarting: try again in a moment.'
    }
}

function Get-AppWorkerState {
    # 'Running', 'Restarting' (no worker now) or 'NotResponding' (silent for a while).
    $worker = $script:App.Worker
    if (-not $worker) {
        return 'Restarting'
    }
    # Silence is counted from the later of its last beat and the end of a pause (a sleep).
    $since = [Math]::Max([long]$worker.Link['Heartbeat'], [long]$script:App.ResumedAt)
    if ([Environment]::TickCount64 - $since -gt $script:WorkerStaleMs) {
        return 'NotResponding'
    }
    'Running'
}

function Open-AppWindow {
    # Shows the main window, filled with the latest snapshot.
    $state = Get-AppWorkerState
    Update-MainWindow -View (ConvertTo-WindowView -Snapshot $script:App.LastSnapshot -Worker $state) -Confirm:$false
    Show-MainWindow
}

function Stop-App {
    # The tray menu's Exit: monitoring stops, the connection stays up. The worker closes the AT
    # port; the UI thread ends once it has, or after ExitWaitMs.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The user asked for it from the tray menu; it changes nothing outside the app.')]
    param()

    $app = $script:App
    if ($app.Exiting) {
        return
    }
    $app.Exiting = $true
    $app.ExitAt = [Environment]::TickCount64 + $script:ExitWaitMs
    $script:MainWindow.Exiting = $true
    if ($app.Worker) {
        Stop-WorkerRunspace -Worker $app.Worker -Confirm:$false
    }
    Write-UiLog -Level 'Info' -Message 'Exiting: monitoring stops, the connection stays as it is.'
}

function New-AppTray {
    # The tray icon and its menu.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object; changes no system state.')]
    param()

    $tray = [System.Windows.Forms.NotifyIcon]::new()
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    [void]$menu.Items.Add('Open', $null, { Open-AppWindow })
    [void]$menu.Items.Add('Check now', $null, { Send-AppCommand -Kind 'ConnectNow' })
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    [void]$menu.Items.Add('Exit', $null, { Stop-App })
    $tray.ContextMenuStrip = $menu
    $tray.Text = 'FM350-GL'
    $tray.Add_MouseClick({
            $click = $args[1]
            if ($click.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                Open-AppWindow
            }
        })
    $tray
}

function Update-App {
    <#
    .SYNOPSIS
        One tick of the UI thread: supervises the worker and shows its latest snapshot.
    .DESCRIPTION
        Releases workers that finished; replaces the current one when it ended or hangs
        (Resolve-SupervisorAction), after the delay it decides; starts the next one when due;
        on exit, ends the UI loop once the worker has closed the AT port. Shows the window when
        a second launch asked for it, and redraws the tray icon, its tooltip and the window when
        the snapshot or the worker's state changed. Never waits on the worker.
    .EXAMPLE
        $timer.Add_Tick({ Update-App })
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The UI thread''s tick: what it starts and stops supports ShouldProcess itself.')]
    [CmdletBinding()]
    param()

    $app = $script:App
    $now = [Environment]::TickCount64
    if ($app.LastTick -and $now - $app.LastTick -gt $script:UiPauseMs) {
        $app.ResumedAt = $now
        $pause = (($now - $app.LastTick) / 1000).ToString('0', [cultureinfo]::InvariantCulture)
        Write-UiLog -Level 'Info' -Message "Resumed after a pause of $pause s (the computer slept?)."
    }
    $app.LastTick = $now

    foreach ($old in @($app.Retiring)) {
        if (Complete-WorkerRunspace -Worker $old) {
            [void]$app.Retiring.Remove($old)
            Write-UiLog -Level 'Info' -Message "Worker $($old.Generation), replaced earlier, has ended."
        }
    }

    $current = $app.Worker
    if ($current) {
        foreach ($message in @(Receive-WorkerMessage -Worker $current)) {
            Write-UiLog -Level 'Warning' -Message $message
        }
        $snapshot = $current.Link['Snapshot']
        if ($snapshot) {
            $app.LastSnapshot = $snapshot
        }
        $decision = Resolve-SupervisorAction -Ended:$current.Handle.IsCompleted -HeartbeatAgeMs ($now - $current.Link['Heartbeat']) `
            -UptimeMs ($now - $current.Started) -Failures $app.Failures -Stopping:$app.Exiting -SinceResumeMs ($now - $app.ResumedAt)
        if ($decision.Action -ne 'None') {
            $app.Worker = $null
            $app.Failures = $decision.Failures
            $app.RestartAt = $now + $decision.DelayMs
            $delay = ($decision.DelayMs / 1000).ToString('0', [cultureinfo]::InvariantCulture)
            if ($decision.Action -eq 'Replace') {
                Stop-WorkerRunspace -Worker $current -Abandon -Confirm:$false
                $app.Retiring.Add($current)
                Write-UiLog -Level 'Error' -Message "Worker $($current.Generation) is not responding: a new one starts in $delay s."
            }
            else {
                [void](Complete-WorkerRunspace -Worker $current)
                Write-UiLog -Level 'Error' -Message "Worker $($current.Generation) ended ($($current.Reason)): a new one starts in $delay s."
            }
        }
    }
    elseif (-not $app.Exiting -and $now -ge $app.RestartAt) {
        Start-AppWorker
    }

    if ($app.Exiting) {
        $done = -not $app.Worker -or (Complete-WorkerRunspace -Worker $app.Worker)
        if ($done -or $now -ge $app.ExitAt) {
            if ($done) {
                $app.Worker = $null
            }
            $app.Dispatcher.InvokeShutdown()
        }
        return
    }

    if ($app.Instance.ShowEvent.WaitOne(0)) {
        Open-AppWindow
    }

    $state = Get-AppWorkerState
    $snapshot = $app.LastSnapshot
    $version = if ($snapshot) { $snapshot.Version } else { -1 }
    if ($version -eq $app.ShownVersion -and $state -eq $app.ShownWorker) {
        return
    }
    $app.ShownVersion = $version
    $app.ShownWorker = $state
    [void](Set-TrayIcon -NotifyIcon $app.Tray -Icon (Resolve-TrayIcon -Snapshot $snapshot -Worker $state) -State $app.TrayState -Confirm:$false)
    $app.Tray.Text = ConvertTo-TrayText -Snapshot $snapshot -Worker $state
    if ($script:MainWindow.Window.IsVisible) {
        Update-MainWindow -View (ConvertTo-WindowView -Snapshot $snapshot -Worker $state) -Confirm:$false
    }
}

function Start-Fm350App {
    <#
    .SYNOPSIS
        Runs the tray app until the user exits it.
    .DESCRIPTION
        One instance per machine (Enter-AppInstance): a second launch shows the first one's
        window and returns. The worker runs in a runspace of its own and owns the modem's AT
        port; this thread shows the tray icon and the main window and supervises the worker.
        Exiting stops monitoring only: the modem stays registered, the data context active, the
        adapter configured.

        -Simulated runs against the simulated modem of -Scenario (New-SimulatedDevice): no
        device, no administrator rights, nothing changed on the system; its settings, secrets
        and log live in a folder of their own, and it can run beside the real app.
        -ObserveOnly reads and never writes. -Hidden starts in the tray, without the window.

        The app needs administrator rights to configure the modem's network adapter; without
        them it says so and leaves the adapter alone.
    .EXAMPLE
        Start-Fm350App -Simulated -Scenario PinRequired
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Runs the app until the user exits it: what changes the modem or the system is the user''s command or the worker''s, each under its own rules.')]
    [CmdletBinding()]
    param(
        [switch] $Simulated,

        [ValidateSet('Online', 'Connect', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'NoDriver',
            'Settling', 'DataPathDown', 'IcmpDropped', 'RegistrationLost', 'ModemHung', 'Unrecoverable')]
        [string] $Scenario = 'Online',

        [switch] $ObserveOnly,

        [switch] $Hidden
    )

    $name = if ($Simulated) { 'fibocom-fm350-gl-windows-gui-simulated' } else { 'fibocom-fm350-gl-windows-gui' }
    $instance = Enter-AppInstance -Name $name
    if (-not $instance.Owned) {
        Write-Verbose 'The app is already running: its window is brought to the front.'
        return
    }

    $root = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'fibocom-fm350-gl-windows-gui'
    $options = @{}
    $logFolder = Join-Path -Path $root -ChildPath 'logs'
    if ($Simulated) {
        $options['Simulation'] = New-SimulatedDevice -Scenario $Scenario
        $options['DataFolder'] = Join-Path -Path $root -ChildPath 'simulated'
        $logFolder = Join-Path -Path $options['DataFolder'] -ChildPath 'logs'
    }
    if ($ObserveOnly) {
        $options['ObserveOnly'] = $true
    }
    $script:App = @{
        Instance      = $instance
        WorkerOptions = $options
        LogFolder     = $logFolder
        Worker        = $null
        Retiring      = [System.Collections.Generic.List[object]]::new()
        Generation    = 0
        Failures      = 0
        RestartAt     = 0
        LastSnapshot  = $null
        Exiting       = $false
        ExitAt        = 0
        Dispatcher    = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
        Tray          = $null
        TrayState     = @{}
        ShownVersion  = $null
        ShownWorker   = $null
        LastTick      = $null
        ResumedAt     = [Environment]::TickCount64
    }
    $timer = $null
    Write-UiLog -Level 'Info' -Message "App started$(if ($Simulated) { " - simulated, scenario $Scenario" })$(if ($ObserveOnly) { ' - observe only' })"
    try {
        $script:App.Dispatcher.Add_UnhandledException({
                $failure = $args[1]
                Write-UiLog -Level 'Error' -Message "UI error: $($failure.Exception.Message)"
                $failure.Handled = $true
            })
        [void](New-MainWindow -Send { param($kind, $parameter) Send-AppCommand -Kind $kind -Parameter $parameter })
        $script:App.Tray = New-AppTray
        Start-AppWorker
        Update-App
        $script:App.Tray.Visible = $true
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [timespan]::FromMilliseconds($script:UiTickMs)
        $timer.Add_Tick({ Update-App })
        $timer.Start()
        if (-not $Hidden) {
            Open-AppWindow
        }
        [System.Windows.Threading.Dispatcher]::Run()
    }
    finally {
        if ($timer) {
            $timer.Stop()
        }
        $app = $script:App
        if ($app.Tray) {
            $app.Tray.Visible = $false
            $app.Tray.ContextMenuStrip.Dispose()
            $app.Tray.Dispose()
        }
        if ($app.TrayState['Handle']) {
            Remove-TrayIconHandle -Handle $app.TrayState['Handle'] -Confirm:$false
        }
        if ($script:MainWindow) {
            $script:MainWindow.Exiting = $true
            $script:MainWindow.Window.Close()
        }
        foreach ($worker in @($app.Worker) + @($app.Retiring)) {
            if ($worker) {
                Stop-WorkerRunspace -Worker $worker -Confirm:$false
                [void](Complete-WorkerRunspace -Worker $worker)
            }
        }
        Exit-AppInstance -Instance $instance
        Write-UiLog -Level 'Info' -Message 'App stopped.'
    }
}
