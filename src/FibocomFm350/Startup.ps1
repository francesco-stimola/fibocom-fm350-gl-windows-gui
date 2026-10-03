# Starting the app when the user signs in (ARCHITECTURE -> Installing and updating): the
# installer's "Start at logon" task, off until the user turns it on in the window. The worker reads
# it and changes it - changing it needs administrator rights, which the installed app has.

# The task, as the installer names it (Get-AppInstallLayout; a test holds the two equal).
$script:LogonTaskPath = '\fibocom-fm350-gl-windows-gui\'
$script:LogonTaskName = 'Start at logon'

function Get-AppLogonTask {
    <#
    .SYNOPSIS
        Whether the app starts when the user signs in to Windows.
    .DESCRIPTION
        Reads the installer's logon task: $true when it is on, $false when it is off, nothing
        when there is none - the app is not installed. Reads only.
    .EXAMPLE
        Get-AppLogonTask
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $task = Get-ScheduledTask -TaskPath $script:LogonTaskPath -TaskName $script:LogonTaskName -ErrorAction SilentlyContinue
    if ($task) {
        [string]$task.State -ne 'Disabled'
    }
}

function Set-AppLogonTask {
    <#
    .SYNOPSIS
        Turns the app's start at sign-in on or off.
    .DESCRIPTION
        Enables or disables the installer's logon task; never creates or deletes it. Needs
        administrator rights; throws when Windows refuses, or there is no such task.
    .EXAMPLE
        Set-AppLogonTask -Enabled $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [bool] $Enabled
    )

    $what = if ($Enabled) { 'Turn the start at sign-in on' } else { 'Turn the start at sign-in off' }
    if (-not $PSCmdlet.ShouldProcess("$script:LogonTaskPath$script:LogonTaskName", $what)) {
        return
    }
    if ($Enabled) {
        [void](Enable-ScheduledTask -TaskPath $script:LogonTaskPath -TaskName $script:LogonTaskName -ErrorAction Stop)
    }
    else {
        [void](Disable-ScheduledTask -TaskPath $script:LogonTaskPath -TaskName $script:LogonTaskName -ErrorAction Stop)
    }
}
