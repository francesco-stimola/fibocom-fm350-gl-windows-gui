# The installer: copies the app under Program Files, registers the tasks that start it elevated
# and the Start-menu shortcut, and removes all of it again. Design: docs/ARCHITECTURE.md ->
# Installing and updating.

$script:AppName = 'fibocom-fm350-gl-windows-gui'

# The program's name, as the Start menu, Windows' list of installed apps and the window's title
# show it. The tray's tooltip says FM350-GL: the modem's state.
$script:DisplayName = 'Fibocom FM350-GL Windows GUI'

# The project's page, which the list of installed apps links.
$script:ProjectPage = 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui'

# The task folder and its two tasks: the app hidden in the tray at logon, and the app with its
# window, which the shortcut runs.
$script:TaskPath = "\$script:AppName\"
$script:LogonTaskName = 'Start at logon'
$script:OpenTaskName = 'Open'

# How long the installer waits for a running app to exit. Exit waits up to 5 s for the worker to
# close the AT port, then ends the process.
$script:AppExitWaitMs = 30000

# What a package holds, and nothing else is copied: an "extract here" into a busy folder never
# takes the folder along.
$script:PackageEntries = @('install.cmd', 'uninstall.cmd', 'Start-Fm350.ps1', 'App', 'FibocomFm350', 'Installer')
$script:OptionalPackageEntries = @('LICENSE', 'README.md', 'CHANGELOG.md')

# The files that tell a package from any folder.
$script:PackageMarkers = @('Start-Fm350.ps1', 'App\Start-Fm350App.ps1', 'FibocomFm350\FibocomFm350.psd1', 'Installer\Invoke-Fm350Setup.ps1')

# Who may write the app's files: SYSTEM, Administrators, TrustedInstaller.
$script:AdminSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')

# The rights that change a file or a folder, or what it holds.
$script:WriteRights = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'

function Get-AppInstallLayout {
    <#
    .SYNOPSIS
        Where the installed app, its tasks, its shortcut and the user's data are.
    .DESCRIPTION
        Every folder comes from Windows' known folders, never from an environment variable, which
        the user can set (docs/AT-COMMANDS.md section 11.2); the parameters let tests put them
        elsewhere. Returns InstallFolder (under Program Files), StagingFolder and RetiredFolder
        (beside it, for an update), Launcher (Start-Fm350.ps1 in it), Uninstaller (uninstall.cmd in
        it), Icon, WindowsPowerShell, CommandShell and SchTasks (in the system folder), System,
        TaskPath, LogonTaskName, OpenTaskName, Shortcut (in the user's Start menu), UninstallEntry
        (the app's key in Windows' list of installed apps, docs/AT-COMMANDS.md section 11.2) and
        UserData (the settings, secrets and logs folders).
    .EXAMPLE
        (Get-AppInstallLayout).InstallFolder
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $ProgramFiles = [Environment]::GetFolderPath('ProgramFiles'),

        [string] $System = [Environment]::GetFolderPath('System'),

        [string] $Programs = [Environment]::GetFolderPath('Programs'),

        [string] $RoamingData = [Environment]::GetFolderPath('ApplicationData'),

        [string] $LocalData = [Environment]::GetFolderPath('LocalApplicationData'),

        [string] $UninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $folder = Join-Path -Path $ProgramFiles -ChildPath $script:AppName
    [pscustomobject]@{
        InstallFolder     = $folder
        StagingFolder     = "$folder.new"
        RetiredFolder     = "$folder.old"
        Launcher          = Join-Path -Path $folder -ChildPath 'Start-Fm350.ps1'
        Uninstaller       = Join-Path -Path $folder -ChildPath 'uninstall.cmd'
        CommandShell      = Join-Path -Path $System -ChildPath 'cmd.exe'
        UninstallEntry    = Join-Path -Path $UninstallKey -ChildPath $script:AppName
        Icon              = Join-Path -Path $folder -ChildPath "App\$script:AppName.ico"
        WindowsPowerShell = Join-Path -Path $System -ChildPath 'WindowsPowerShell\v1.0\powershell.exe'
        SchTasks          = Join-Path -Path $System -ChildPath 'schtasks.exe'
        System            = $System
        TaskPath          = $script:TaskPath
        LogonTaskName     = $script:LogonTaskName
        OpenTaskName      = $script:OpenTaskName
        Shortcut          = Join-Path -Path $Programs -ChildPath "$script:DisplayName.lnk"
        UserData          = [string[]]@((Join-Path -Path $RoamingData -ChildPath $script:AppName), (Join-Path -Path $LocalData -ChildPath $script:AppName))
    }
}

function ConvertTo-CommandLine {
    <#
    .SYNOPSIS
        Joins arguments into one command line, as Windows splits it again.
    .DESCRIPTION
        An argument with a blank, or an empty one, is quoted, and its trailing backslashes doubled
        before the closing quote. An argument carrying a double quote is refused: no path can.
        Start-Fm350.ps1 does the same in Windows PowerShell.
    .EXAMPLE
        ConvertTo-CommandLine -Argument '-File', 'C:\Program Files\app\Start-Fm350.ps1'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]] $Argument
    )

    $parts = foreach ($item in $Argument) {
        if ($item.Contains('"')) {
            throw [System.ArgumentException]::new("An argument can't carry a double quote: $item", 'Argument')
        }
        if ($item -eq '' -or $item -match '\s') {
            '"' + ($item -replace '(\\+)$', '$1$1') + '"'
        }
        else {
            $item
        }
    }
    $parts -join ' '
}

function New-AppTaskDefinition {
    <#
    .SYNOPSIS
        Describes one of the app's scheduled tasks: what it runs, as whom, and how.
    .DESCRIPTION
        A pure function. -Kind Logon: at the user's logon, the app hidden in the tray, one
        instance at a time. -Kind Open: on demand - the Start-menu shortcut runs it -, the app
        with its window; a second run while one runs starts it again, which brings the running
        app's window up.

        Both run Windows PowerShell from the system folder with the launcher from the install
        folder, both admin-only (invariant 10), by literal paths - never a variable the user's
        environment could change -, for -UserSid, interactive, with the highest privileges.
        Task Scheduler's defaults would stop the app after 72 hours, keep it from starting on
        batteries, stop it when the computer goes on batteries, and run it at below-normal
        priority (docs/AT-COMMANDS.md section 11.2): none of that applies. Returns what
        Register-AppTask registers.
    .EXAMPLE
        New-AppTaskDefinition -Layout (Get-AppInstallLayout) -UserSid $sid -Kind Logon
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Describes a task in memory; Register-AppTask registers it.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Layout,

        [Parameter(Mandatory)]
        [ValidatePattern('^S-1-5-21-\d+-\d+-\d+-\d+$')]
        [string] $UserSid,

        [Parameter(Mandatory)]
        [ValidateSet('Logon', 'Open')]
        [string] $Kind,

        # Off: registered, but Task Scheduler doesn't run it - the logon task until the user
        # turns it on (decided 2026-10-03).
        [bool] $Enabled = $true
    )

    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $Layout.Launcher)
    if ($Kind -eq 'Logon') {
        $arguments += '-Hidden'
    }
    [pscustomobject]@{
        TaskPath                   = $Layout.TaskPath
        TaskName                   = if ($Kind -eq 'Logon') { $Layout.LogonTaskName } else { $Layout.OpenTaskName }
        Description                = if ($Kind -eq 'Logon') { "Starts $script:DisplayName in the tray at logon." } else { "Opens $script:DisplayName; its Start-menu shortcut runs this task." }
        Execute                    = $Layout.WindowsPowerShell
        Argument                   = ConvertTo-CommandLine -Argument $arguments
        WorkingDirectory           = $Layout.System
        AtLogOn                    = $Kind -eq 'Logon'
        UserSid                    = $UserSid
        LogonType                  = 'Interactive'
        RunLevel                   = 'Highest'
        MultipleInstances          = if ($Kind -eq 'Logon') { 'IgnoreNew' } else { 'Parallel' }
        Priority                   = 5
        ExecutionTimeLimit         = [timespan]::Zero
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        Enabled                    = $Enabled
    }
}

function Test-AdminOnlyAccess {
    <#
    .SYNOPSIS
        Decides whether only administrators can change a file or a folder.
    .DESCRIPTION
        A pure decision over -Owner (a SID) and -Rule (the access rules, each with Sid,
        FileSystemRights, AccessControlType, InheritanceFlags and PropagationFlags). Admin-only
        when the owner is SYSTEM, Administrators or TrustedInstaller - an owner can always change
        the rules - and no rule allows any right that changes the object or what it holds to
        anyone else. A rule that only passes to children (inherit-only) doesn't count for the
        object itself: the children are checked on their own. Returns Allowed and Offenders (who
        else could write, or the owner).
    .EXAMPLE
        Test-AdminOnlyAccess -Owner 'S-1-5-32-544' -Rule $rules
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Owner,

        [AllowEmptyCollection()]
        [object[]] $Rule = @()
    )

    $offenders = [System.Collections.Generic.List[string]]::new()
    if ($Owner -notin $script:AdminSids) {
        $offenders.Add("owner $Owner")
    }
    foreach ($item in $Rule) {
        $inheritOnly = ([System.Security.AccessControl.PropagationFlags]$item.PropagationFlags).HasFlag([System.Security.AccessControl.PropagationFlags]::InheritOnly)
        $writes = ([System.Security.AccessControl.FileSystemRights]$item.FileSystemRights -band $script:WriteRights) -ne 0
        if ([string]$item.AccessControlType -eq 'Allow' -and -not $inheritOnly -and $writes -and $item.Sid -notin $script:AdminSids -and -not $offenders.Contains($item.Sid)) {
            $offenders.Add($item.Sid)
        }
    }
    [pscustomobject]@{ Allowed = $offenders.Count -eq 0; Offenders = [string[]]$offenders.ToArray() }
}

function Get-PathAccess {
    <#
    .SYNOPSIS
        Reads a file's or a folder's owner and access rules, as SIDs.
    .DESCRIPTION
        Returns what Test-AdminOnlyAccess takes: Owner and Rule. Reads the access sections only:
        the audit rules need a privilege the installer has no use for.
    .EXAMPLE
        Get-PathAccess -Path 'C:\Program Files\fibocom-fm350-gl-windows-gui'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $sections = [System.Security.AccessControl.AccessControlSections]'Access, Owner'
    $item = Get-Item -LiteralPath $Path -Force
    $security = if ($item -is [System.IO.DirectoryInfo]) {
        [System.IO.FileSystemAclExtensions]::GetAccessControl($item, $sections)
    }
    else {
        [System.IO.FileSystemAclExtensions]::GetAccessControl([System.IO.FileInfo]$item, $sections)
    }
    $sid = [System.Security.Principal.SecurityIdentifier]
    [pscustomobject]@{
        Owner = $security.GetOwner($sid).Value
        Rule  = [object[]]@($security.GetAccessRules($true, $true, $sid) | ForEach-Object {
                [pscustomobject]@{
                    Sid               = $_.IdentityReference.Value
                    FileSystemRights  = $_.FileSystemRights
                    AccessControlType = [string]$_.AccessControlType
                    InheritanceFlags  = $_.InheritanceFlags
                    PropagationFlags  = $_.PropagationFlags
                }
            })
    }
}

function Test-AppPackage {
    <#
    .SYNOPSIS
        Whether a folder holds the app's package: the files every package has.
    .EXAMPLE
        Test-AppPackage -Path $PSScriptRoot\..
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    @($script:PackageMarkers | Where-Object { -not (Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath $_) -PathType Leaf) }).Count -eq 0
}

function Copy-AppPackage {
    <#
    .SYNOPSIS
        Copies the app's package - its own entries, nothing else - into a new folder.
    .DESCRIPTION
        -Destination must not exist yet: it is created, and inherits its parent's access rules
        (under Program Files, admin-only). The files lose the mark of the web a downloaded zip
        passes to them, so nothing asks about them later. Returns the files copied.
    .EXAMPLE
        Copy-AppPackage -Source $source -Destination $layout.StagingFolder
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Source,

        [Parameter(Mandatory)]
        [string] $Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        throw [System.IO.IOException]::new((Get-SetupText 'Install.FolderExists' $Destination))
    }
    if (-not $PSCmdlet.ShouldProcess($Destination, 'Copy the app')) {
        return
    }
    [void](New-Item -ItemType Directory -Path $Destination)
    $entries = @($script:PackageEntries) + @($script:OptionalPackageEntries | Where-Object { Test-Path -LiteralPath (Join-Path -Path $Source -ChildPath $_) })
    foreach ($entry in $entries) {
        Copy-Item -LiteralPath (Join-Path -Path $Source -ChildPath $entry) -Destination (Join-Path -Path $Destination -ChildPath $entry) -Recurse -Force -ErrorAction Stop
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Force)) {
        Unblock-File -LiteralPath $file.FullName
        $file.FullName
    }
}

function Test-AppFolderAccess {
    <#
    .SYNOPSIS
        Checks that only administrators can change a folder and everything in it.
    .DESCRIPTION
        Returns Allowed and Offenders: the paths someone else could change, with who. The folder
        and every file and folder in it are checked (Get-PathAccess, Test-AdminOnlyAccess).
    .EXAMPLE
        (Test-AppFolderAccess -Path $layout.StagingFolder).Allowed
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $offenders = [System.Collections.Generic.List[string]]::new()
    $items = @(Get-Item -LiteralPath $Path -Force) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
    foreach ($item in $items) {
        $access = Get-PathAccess -Path $item.FullName
        $verdict = Test-AdminOnlyAccess -Owner $access.Owner -Rule $access.Rule
        if (-not $verdict.Allowed) {
            $offenders.Add("$($item.FullName): $($verdict.Offenders -join ', ')")
        }
    }
    [pscustomobject]@{ Allowed = $offenders.Count -eq 0; Offenders = [string[]]$offenders.ToArray() }
}

function Stop-AppInstance {
    <#
    .SYNOPSIS
        Asks the running app to exit, waits until it has, and keeps any other from starting.
    .DESCRIPTION
        The app holds a machine-wide mutex while it runs and waits on an exit event of its Windows
        session (Enter-AppInstance); exiting stops monitoring only, the connection stays as it is.
        This function signals the event and waits for the mutex up to -TimeoutMs, then holds it:
        an app started meanwhile finds it taken and exits. Returns WasRunning, Stopped and Mutex
        - held when Stopped -, which the caller releases with Exit-AppInstallLock, on the same
        thread. Not Stopped: the app runs in another Windows session, or didn't exit in time.
    .EXAMPLE
        $lock = Stop-AppInstance
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidatePattern('^[A-Za-z0-9-]+$')]
        [string] $Name = $script:AppName,

        [ValidateRange(0, 600000)]
        [int] $TimeoutMs = $script:AppExitWaitMs
    )

    $mutex = [System.Threading.Mutex]::new($false, "Global\$Name")
    $result = { param($running, $held) [pscustomobject]@{ WasRunning = $running; Stopped = $held; Mutex = if ($held) { $mutex } else { $null } } }
    try {
        if ($mutex.WaitOne(0)) {
            return & $result $false $true
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        # Its last owner died holding it: nothing runs.
        return & $result $false $true
    }
    if (-not $PSCmdlet.ShouldProcess('the running app', 'Ask it to exit')) {
        $mutex.Dispose()
        return & $result $true $false
    }
    $exit = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting("Local\$Name-exit", [ref]$exit)) {
        [void]$exit.Set()
        $exit.Dispose()
    }
    $held = $false
    try {
        $held = $mutex.WaitOne($TimeoutMs)
    }
    catch [System.Threading.AbandonedMutexException] {
        $held = $true
    }
    if (-not $held) {
        $mutex.Dispose()
    }
    & $result $true $held
}

function Exit-AppInstallLock {
    <#
    .SYNOPSIS
        Releases the mutex Stop-AppInstance held, so that the app can start again.
    .EXAMPLE
        Exit-AppInstallLock -Lock $lock
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Lock
    )

    if ($Lock.Mutex) {
        try {
            $Lock.Mutex.ReleaseMutex()
        }
        catch [System.ApplicationException] {
            Write-Verbose 'The mutex was not held by this thread.'
        }
        $Lock.Mutex.Dispose()
    }
}

function Register-AppTask {
    <#
    .SYNOPSIS
        Registers - or replaces - one of the app's scheduled tasks from New-AppTaskDefinition's.
    .EXAMPLE
        Register-AppTask -Definition (New-AppTaskDefinition -Layout $layout -UserSid $sid -Kind Logon)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $Definition
    )

    if (-not $PSCmdlet.ShouldProcess("$($Definition.TaskPath)$($Definition.TaskName)", 'Register the scheduled task')) {
        return
    }
    # The account's name, for the logon trigger: the SID names the same account.
    $account = ([System.Security.Principal.SecurityIdentifier]$Definition.UserSid).Translate([System.Security.Principal.NTAccount]).Value
    $action = New-ScheduledTaskAction -Execute $Definition.Execute -Argument $Definition.Argument -WorkingDirectory $Definition.WorkingDirectory
    $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType $Definition.LogonType -RunLevel $Definition.RunLevel
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit $Definition.ExecutionTimeLimit -AllowStartIfOnBatteries:$Definition.AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries:$Definition.DontStopIfGoingOnBatteries -MultipleInstances $Definition.MultipleInstances -Priority $Definition.Priority -Compatibility Win8 `
        -Disable:(-not $Definition.Enabled)
    $task = @{
        TaskPath    = $Definition.TaskPath
        TaskName    = $Definition.TaskName
        Description = $Definition.Description
        Action      = $action
        Principal   = $principal
        Settings    = $settings
    }
    if ($Definition.AtLogOn) {
        $task['Trigger'] = New-ScheduledTaskTrigger -AtLogOn -User $account
    }
    [void](Register-ScheduledTask @task -Force -ErrorAction Stop)
}

function Unregister-AppTask {
    <#
    .SYNOPSIS
        Removes the app's scheduled tasks and their folder. Returns the tasks removed.
    .EXAMPLE
        Unregister-AppTask -Layout (Get-AppInstallLayout)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Layout
    )

    foreach ($task in @(Get-ScheduledTask -TaskPath $Layout.TaskPath -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess("$($task.TaskPath)$($task.TaskName)", 'Remove the scheduled task')) {
            Unregister-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
            "$($task.TaskPath)$($task.TaskName)"
        }
    }
    Remove-AppTaskFolder -TaskPath $Layout.TaskPath -Confirm:$false
}

function Remove-AppTaskFolder {
    # The ScheduledTasks module removes tasks, not folders: Task Scheduler's own COM interface does.
    # A folder that isn't there is nothing to do.
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $TaskPath)

    if (-not $PSCmdlet.ShouldProcess($TaskPath, 'Remove the task folder')) {
        return
    }
    $service = New-Object -ComObject 'Schedule.Service'
    try {
        $service.Connect()
        $name = $TaskPath.Trim('\')
        try {
            [void]$service.GetFolder($TaskPath.TrimEnd('\'))
        }
        catch {
            return
        }
        $service.GetFolder('\').DeleteFolder($name, 0)
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($service)
    }
}

function New-AppShortcut {
    <#
    .SYNOPSIS
        Creates the Start-menu shortcut, which runs the app's Open task.
    .DESCRIPTION
        The shortcut runs schtasks from the system folder, minimized: the task starts the app
        elevated, without a UAC prompt. Running the task asks for no administrator rights.
    .EXAMPLE
        New-AppShortcut -Layout (Get-AppInstallLayout)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $Layout
    )

    if (-not $PSCmdlet.ShouldProcess($Layout.Shortcut, 'Create the Start-menu shortcut')) {
        return
    }
    $folder = Split-Path -Parent $Layout.Shortcut
    if (-not (Test-Path -LiteralPath $folder)) {
        [void](New-Item -ItemType Directory -Path $folder -Force)
    }
    $shell = New-Object -ComObject 'WScript.Shell'
    try {
        $link = $shell.CreateShortcut($Layout.Shortcut)
        try {
            $link.TargetPath = $Layout.SchTasks
            $link.Arguments = ConvertTo-CommandLine -Argument '/run', '/tn', "$($Layout.TaskPath)$($Layout.OpenTaskName)"
            $link.WorkingDirectory = $Layout.System
            # Minimized: schtasks is a console program, here for a moment.
            $link.WindowStyle = 7
            $link.Description = Get-SetupText 'Install.ShortcutTip'
            if (Test-Path -LiteralPath $Layout.Icon) {
                $link.IconLocation = "$($Layout.Icon),0"
            }
            $link.Save()
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($link)
        }
    }
    finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Remove-AppFolder {
    # Deletes a folder of the app, if it is there; returns whether it was.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path) -or -not $PSCmdlet.ShouldProcess($Path, 'Delete the folder')) {
        return $false
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    $true
}

function Register-AppUninstallEntry {
    <#
    .SYNOPSIS
        Lists the installed app in Windows' installed apps, where uninstalling it runs uninstall.cmd.
    .DESCRIPTION
        Writes the app's key under the Uninstall key (docs/AT-COMMANDS.md section 11.2): its name,
        the installed package's version, its icon, folder, size and page, the command that
        uninstalls it, and no Modify or Repair - there is nothing to change but to install again.
        Written whole at every installation. Needs administrator rights.
    .EXAMPLE
        Register-AppUninstallEntry -Layout (Get-AppInstallLayout)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $Layout
    )

    if (-not $PSCmdlet.ShouldProcess($Layout.UninstallEntry, 'List the app in Windows'' installed apps')) {
        return
    }
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $Layout.InstallFolder -ChildPath 'FibocomFm350\FibocomFm350.psd1')
    $bytes = (Get-ChildItem -LiteralPath $Layout.InstallFolder -Recurse -File | Measure-Object -Property Length -Sum).Sum
    $values = [ordered]@{
        DisplayName     = $script:DisplayName
        DisplayVersion  = [string]$manifest.ModuleVersion
        InstallLocation = $Layout.InstallFolder
        # Through cmd, which runs a batch file: /c drops the outer pair of the doubled quotes,
        # the inner pair keeps the path's spaces whole.
        UninstallString = "`"$($Layout.CommandShell)`" /c `"`"$($Layout.Uninstaller)`"`""
        URLInfoAbout    = $script:ProjectPage
    }
    if (Test-Path -LiteralPath $Layout.Icon) {
        $values['DisplayIcon'] = $Layout.Icon
    }
    if (Test-Path -LiteralPath $Layout.UninstallEntry) {
        Remove-Item -LiteralPath $Layout.UninstallEntry -Recurse -Force -ErrorAction Stop
    }
    [void](New-Item -Path $Layout.UninstallEntry -Force -ErrorAction Stop)
    foreach ($name in $values.Keys) {
        [void](New-ItemProperty -LiteralPath $Layout.UninstallEntry -Name $name -PropertyType String -Value $values[$name] -ErrorAction Stop)
    }
    $numbers = [ordered]@{ NoModify = 1; NoRepair = 1; EstimatedSize = [int][Math]::Ceiling($bytes / 1KB) }
    foreach ($name in $numbers.Keys) {
        [void](New-ItemProperty -LiteralPath $Layout.UninstallEntry -Name $name -PropertyType DWord -Value $numbers[$name] -ErrorAction Stop)
    }
}

function Remove-AppUninstallEntry {
    # Takes the app off Windows' installed apps; returns whether it was listed.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([object] $Layout)

    if (-not (Test-Path -LiteralPath $Layout.UninstallEntry) -or -not $PSCmdlet.ShouldProcess($Layout.UninstallEntry, 'Take the app off Windows'' installed apps')) {
        return $false
    }
    Remove-Item -LiteralPath $Layout.UninstallEntry -Recurse -Force -ErrorAction Stop
    $true
}

function Install-Fm350App {
    <#
    .SYNOPSIS
        Installs the app from a package, or updates it: copies it under Program Files, registers
        its tasks, creates its shortcut, and starts it.
    .DESCRIPTION
        Needs administrator rights. In order:
        - the running app is asked to exit and its mutex held, so none starts meanwhile
          (Stop-AppInstance): monitoring stops, the connection stays up. An app that doesn't exit
          stops the installation before anything changes;
        - the package's own entries are copied into a folder beside the install folder, their mark
          of the web removed, and the copy checked: only administrators can change any of it
          (invariant 10). Then the old install folder moves aside, the copy takes its place, and
          the old one is deleted; a failure halfway puts the old one back. A package run from the
          install folder itself is not copied: tasks and shortcut are made again;
        - the two tasks are registered (New-AppTaskDefinition) - the logon task off on a first
          installation, as the user left it on an update - and the Start-menu shortcut made,
          with an icon drawn for it and the app's taskbar identity; the app is listed in
          Windows' installed apps (Register-AppUninstallEntry);
        - the mutex is released and, unless -NoStart, the app started with its window - through
          the Open task, as the shortcut would.
        Returns one line per step done. When a step fails after the running app exited, that app
        is started again from the folder in place - the old one put back, or the new one - before
        the failure is thrown: monitoring never stays off because an update failed.
    .EXAMPLE
        Install-Fm350App -Source $packageFolder -UserSid $sid
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Source,

        [Parameter(Mandatory)]
        [ValidatePattern('^S-1-5-21-\d+-\d+-\d+-\d+$')]
        [string] $UserSid,

        [object] $Layout = (Get-AppInstallLayout),

        [switch] $NoStart
    )

    $source = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
    if (-not (Test-AppPackage -Path $source)) {
        throw [System.IO.FileNotFoundException]::new((Get-SetupText 'Install.NotPackage' $source))
    }
    $inPlace = $source -eq [System.IO.Path]::GetFullPath($Layout.InstallFolder).TrimEnd('\')
    $lock = Stop-AppInstance -Confirm:$false
    if (-not $lock.Stopped) {
        throw [System.InvalidOperationException]::new((Get-SetupText 'Install.StillRunning' ($script:AppExitWaitMs / 1000) 'install.cmd'))
    }
    if ($lock.WasRunning) {
        Get-SetupText 'Install.Exited'
    }
    $done = $false
    try {
        if (-not $inPlace) {
            foreach ($leftover in $Layout.StagingFolder, $Layout.RetiredFolder) {
                if (Remove-AppFolder -Path $leftover -Confirm:$false) {
                    Get-SetupText 'Install.Leftover' $leftover
                }
            }
            try {
                $files = @(Copy-AppPackage -Source $source -Destination $Layout.StagingFolder -Confirm:$false)
                $access = Test-AppFolderAccess -Path $Layout.StagingFolder
                if (-not $access.Allowed) {
                    throw [System.UnauthorizedAccessException]::new((Get-SetupText 'Install.NotAdminOnly' ($access.Offenders -join '; ')))
                }
            }
            catch {
                [void](Remove-AppFolder -Path $Layout.StagingFolder -Confirm:$false)
                throw
            }
            Get-SetupText 'Install.Copied' $files.Count
            $replacing = Test-Path -LiteralPath $Layout.InstallFolder
            if ($replacing) {
                Move-Item -LiteralPath $Layout.InstallFolder -Destination $Layout.RetiredFolder -ErrorAction Stop
            }
            try {
                Move-Item -LiteralPath $Layout.StagingFolder -Destination $Layout.InstallFolder -ErrorAction Stop
            }
            catch {
                if ($replacing) {
                    Move-Item -LiteralPath $Layout.RetiredFolder -Destination $Layout.InstallFolder -ErrorAction Continue
                }
                [void](Remove-AppFolder -Path $Layout.StagingFolder -Confirm:$false)
                throw
            }
            Get-SetupText $(if ($replacing) { 'Install.InstalledOver' } else { 'Install.Installed' }) $Layout.InstallFolder
            try {
                [void](Remove-AppFolder -Path $Layout.RetiredFolder -Confirm:$false)
            }
            catch {
                Get-SetupText 'Install.OldFolder' $_.Exception.Message
            }
        }
        # The start at sign-in stays as the user left it; off on a first installation.
        $logonOn = Test-AppLogonTaskOn -Layout $Layout
        foreach ($kind in 'Logon', 'Open') {
            $definition = New-AppTaskDefinition -Layout $Layout -UserSid $UserSid -Kind $kind -Enabled ($kind -eq 'Open' -or $logonOn)
            Register-AppTask -Definition $definition -Confirm:$false
            Get-SetupText $(if ($definition.Enabled) { 'Install.Task' } else { 'Install.TaskOff' }) "$($definition.TaskPath)$($definition.TaskName)"
        }
        Invoke-InstalledApp -Layout $Layout -Failure 'Install.NoIcon' -Script { Export-AppIcon -Path $Layout.Icon -Confirm:$false }
        New-AppShortcut -Layout $Layout -Confirm:$false
        Invoke-InstalledApp -Layout $Layout -Failure 'Install.NoIdentity' -Script { Set-AppShortcutIdentity -Path $Layout.Shortcut -Confirm:$false }
        Get-SetupText 'Install.Shortcut' $Layout.Shortcut
        Register-AppUninstallEntry -Layout $Layout -Confirm:$false
        Get-SetupText 'Install.Entry'
        $done = $true
    }
    finally {
        Exit-AppInstallLock -Lock $lock
        if (-not $done -and $lock.WasRunning) {
            Restart-InstalledApp -Layout $Layout
        }
    }
    if (-not $NoStart) {
        Start-ScheduledTask -TaskPath $Layout.TaskPath -TaskName $Layout.OpenTaskName -ErrorAction Stop
        Get-SetupText 'Install.Starting'
    }
}

function Restart-InstalledApp {
    # After a failed update: the app that was asked to exit started again through its Open task,
    # when the install folder holds a whole package. Never throws - the failure that stopped the
    # installation is the one the caller says -, and says what it did.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts again the app the installation stopped; Install-Fm350App is the operation.')]
    param([object] $Layout)

    try {
        if (-not (Test-AppPackage -Path $Layout.InstallFolder)) {
            throw [System.IO.FileNotFoundException]::new((Get-SetupText 'Install.NotPackage' $Layout.InstallFolder))
        }
        Start-ScheduledTask -TaskPath $Layout.TaskPath -TaskName $Layout.OpenTaskName -ErrorAction Stop
        Get-SetupText 'Install.Restarted'
    }
    catch {
        Get-SetupText 'Install.NotRestarted' $_.Exception.Message
    }
}

function Test-AppLogonTaskOn {
    # Whether the logon task an earlier installation registered is on - the user's choice, which
    # an update keeps. Off when there is none.
    param([object] $Layout)

    $task = Get-ScheduledTask -TaskPath $Layout.TaskPath -TaskName $Layout.LogonTaskName -ErrorAction SilentlyContinue
    [bool]($task -and [string]$task.State -ne 'Disabled')
}

function Invoke-InstalledApp {
    # Runs -Script with the installed app's module loaded: the shortcut's icon, drawn by the app,
    # and its taskbar identity, the app's. What fails is said - -Failure, the text's key - and the
    # installation goes on: the shortcut then has schtasks' icon, or PowerShell's identity.
    param([object] $Layout, [scriptblock] $Script, [string] $Failure)

    try {
        $app = Import-Module -Name (Join-Path -Path $Layout.InstallFolder -ChildPath 'App\FibocomFm350.App.psd1') -PassThru -ErrorAction Stop
        try {
            & $Script
        }
        finally {
            Remove-Module -ModuleInfo $app -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Warning (Get-SetupText $Failure $_.Exception.Message)
    }
}

function Uninstall-Fm350App {
    <#
    .SYNOPSIS
        Removes the app: its tasks, its Start-menu shortcut, its install folder and its entry in
        Windows' installed apps.
    .DESCRIPTION
        Needs administrator rights. The running app is asked to exit first (Stop-AppInstance):
        monitoring stops, the connection stays as it is - nothing on the modem or its adapter is
        undone. An app that doesn't exit stops the uninstallation before anything changes.
        -RemoveUserData also deletes the settings, the stored SIM PIN and APN password, and the
        logs. Returns one line per step done.
    .EXAMPLE
        Uninstall-Fm350App
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object] $Layout = (Get-AppInstallLayout),

        [switch] $RemoveUserData
    )

    $lock = Stop-AppInstance -Confirm:$false
    if (-not $lock.Stopped) {
        throw [System.InvalidOperationException]::new((Get-SetupText 'Install.StillRunning' ($script:AppExitWaitMs / 1000) 'uninstall.cmd'))
    }
    if ($lock.WasRunning) {
        Get-SetupText 'Install.Exited'
    }
    try {
        foreach ($task in @(Unregister-AppTask -Layout $Layout -Confirm:$false)) {
            Get-SetupText 'Uninstall.Task' $task
        }
        if (Test-Path -LiteralPath $Layout.Shortcut) {
            Remove-Item -LiteralPath $Layout.Shortcut -Force -ErrorAction Stop
            Get-SetupText 'Uninstall.Shortcut'
        }
        try {
            foreach ($folder in $Layout.InstallFolder, $Layout.StagingFolder, $Layout.RetiredFolder) {
                if (Remove-AppFolder -Path $folder -Confirm:$false) {
                    Get-SetupText 'Uninstall.Folder' $folder
                }
            }
        }
        catch {
            # The entry stays while what it runs is whole, so the uninstallation can run again from
            # the list; once part of it is gone, an entry that can't uninstall goes too.
            $whole = (Test-AppPackage -Path $Layout.InstallFolder) -and (Test-Path -LiteralPath $Layout.Uninstaller -PathType Leaf)
            if (-not $whole -and (Remove-AppUninstallEntry -Layout $Layout -Confirm:$false)) {
                Get-SetupText 'Uninstall.Entry'
            }
            throw
        }
        # Last: until the folder is gone, the list of installed apps can still run its uninstall.cmd.
        if (Remove-AppUninstallEntry -Layout $Layout -Confirm:$false) {
            Get-SetupText 'Uninstall.Entry'
        }
        if ($RemoveUserData) {
            foreach ($folder in $Layout.UserData) {
                if (Remove-AppFolder -Path $folder -Confirm:$false) {
                    Get-SetupText 'Uninstall.UserData' $folder
                }
            }
        }
    }
    finally {
        Exit-AppInstallLock -Lock $lock
    }
}
