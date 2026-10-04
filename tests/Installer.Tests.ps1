# The installer: the launcher's choice of PowerShell 7 (also run in Windows PowerShell 5.1), the
# install layout, the tasks' definitions, the admin-only check, the package's copy; installing,
# updating and uninstalling into TestDrive with Task Scheduler's cmdlets mocked - these tests
# register no task and write nothing under Program Files -; the running app asked to exit, a
# real one included.

BeforeAll {
    Import-Module "$PSScriptRoot/../src/Installer/FibocomFm350.Installer.psd1" -Force
    $script:src = (Resolve-Path "$PSScriptRoot/../src").Path
    $script:launcher = Join-Path $script:src 'Start-Fm350.ps1'
    $script:system = [Environment]::GetFolderPath('System')
    $script:userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    # The launcher's functions; dot-sourcing it sets its module path, which is put back.
    $saved = $env:PSModulePath
    . $script:launcher
    $env:PSModulePath = $saved

    # A layout with every folder in TestDrive, but the system folder.
    # Folders under the test drive, and the list of installed apps in Pester's test registry key
    # (under HKCU): never the machine's.
    function Get-TestLayout {
        param([string] $Root = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))))
        Get-AppInstallLayout -ProgramFiles (Join-Path $Root 'pf') -System $script:system -Programs (Join-Path $Root 'programs') `
            -RoamingData (Join-Path $Root 'roaming') -LocalData (Join-Path $Root 'local') -UninstallKey "TestRegistry:\$(Split-Path -Leaf $Root)"
    }

    # A package as the release zip extracts it: the repository's src folder.
    function Copy-TestPackage {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:src -Destination $folder -Recurse
        $folder
    }

    # A rule as Get-PathAccess gives it.
    function Get-TestRule {
        param([string] $Sid, [string] $Rights, [string] $Type = 'Allow', [string] $Propagation = 'None')
        [pscustomobject]@{
            Sid               = $Sid
            FileSystemRights  = [System.Security.AccessControl.FileSystemRights]$Rights
            AccessControlType = $Type
            InheritanceFlags  = [System.Security.AccessControl.InheritanceFlags]::None
            PropagationFlags  = [System.Security.AccessControl.PropagationFlags]$Propagation
        }
    }
}

AfterAll {
    Remove-Module FibocomFm350.Installer -ErrorAction SilentlyContinue
}

Describe 'The launcher (Start-Fm350.ps1)' {
    It 'takes <Name>' -ForEach @(
        @{ Name = 'the MSIX package alone'; Candidates = @(@{ Path = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe\pwsh.exe'; Version = '7.6.6'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }); Path = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe\pwsh.exe'; Problem = $null }
        @{ Name = 'the newest of the MSI and the MSIX'; Candidates = @(@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = '7.6.2'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }, @{ Path = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe'; Version = '7.7.0'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }); Path = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.7.0.0_x64__8wekyb3d8bbwe\pwsh.exe'; Problem = $null }
        @{ Name = 'the MSI over an older MSIX'; Candidates = @(@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = '7.6.6'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }, @{ Path = 'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.1.0_x64__8wekyb3d8bbwe\pwsh.exe'; Version = '7.6.1'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }); Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Problem = $null }
        @{ Name = 'nothing: none installed'; Candidates = @(); Path = $null; Problem = 'NotFound' }
        @{ Name = 'nothing: only 7.5'; Candidates = @(@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = '7.5.4'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }); Path = $null; Problem = 'TooOld' }
        @{ Name = 'nothing: outside Program Files'; Candidates = @(@{ Path = 'C:\Users\someone\.dotnet\tools\pwsh.exe'; Version = '7.6.6'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }); Path = $null; Problem = 'Untrusted' }
        @{ Name = 'nothing: in a folder whose name starts like Program Files'; Candidates = @(@{ Path = 'C:\Program Files Evil\pwsh.exe'; Version = '7.6.6'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }); Path = $null; Problem = 'Untrusted' }
        @{ Name = 'nothing: a path that climbs out of Program Files'; Candidates = @(@{ Path = 'C:\Program Files\..\Users\someone\pwsh.exe'; Version = '7.6.6'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }); Path = $null; Problem = 'Untrusted' }
        @{ Name = 'nothing: a signature that is not valid'; Candidates = @(@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = '7.6.6'; Valid = $false; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }); Path = $null; Problem = 'Untrusted' }
        @{ Name = 'nothing: signed by someone else'; Candidates = @(@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = '7.6.6'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Not Microsoft Corporation' }); Path = $null; Problem = 'Untrusted' }
        @{ Name = 'nothing: unsigned'; Candidates = @(@{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = '7.6.6'; Valid = $false; Signer = $null }); Path = $null; Problem = 'Untrusted' }
        @{ Name = 'the trusted one beside an untrusted newer one'; Candidates = @(@{ Path = 'C:\Tools\pwsh.exe'; Version = '7.9.0'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }, @{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = '7.6.0'; Valid = $true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }); Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Problem = $null }
    ) {
        $list = @($Candidates | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Version = [version]$_.Version; SignatureValid = $_.Valid; Signer = $_.Signer } })
        $choice = Select-LauncherPwsh -Candidate $list -ProgramFiles 'C:\Program Files' -Minimum ([version]'7.6.0')
        $choice.Path | Should -Be $Path
        $choice.Problem | Should -Be $Problem
    }

    It 'says what to do for <Problem>' -ForEach @(
        @{ Problem = 'NotFound'; Text = 'not found' }
        @{ Problem = 'TooOld'; Text = 'older than 7.6' }
        @{ Problem = 'Untrusted'; Text = 'signature of Microsoft' }
    ) {
        $text = Get-LauncherProblemText -Problem $Problem
        $text | Should -Match $Text
        $text | Should -Match 'winget install Microsoft.PowerShell'
    }

    It 'installs on <Name>: <Problem>' -ForEach @(
        @{ Name = '64-bit Windows on x64'; Architecture = 9; Width = 64; Problem = $null }
        @{ Name = 'Windows on Arm64'; Architecture = 12; Width = 64; Problem = 'Arm' }
        @{ Name = 'Windows on 32-bit Arm'; Architecture = 5; Width = 32; Problem = 'Arm' }
        @{ Name = '32-bit Windows'; Architecture = 0; Width = 32; Problem = 'NotX64' }
        @{ Name = '32-bit Windows on an x64 processor'; Architecture = 9; Width = 32; Problem = 'NotX64' }
        @{ Name = 'Itanium'; Architecture = 6; Width = 64; Problem = 'NotX64' }
        @{ Name = 'a processor that can''t be read'; Architecture = $null; Width = $null; Problem = $null }
    ) {
        Test-LauncherPlatform -Architecture $Architecture -AddressWidth $Width | Should -Be $Problem
    }

    It 'says why it doesn''t install on <Problem>, and that nothing was installed' -ForEach @(
        @{ Problem = 'Arm'; Text = 'Arm processor' }
        @{ Problem = 'NotX64'; Text = '64-bit Windows on an x64' }
    ) {
        $said = Get-LauncherProblemText -Problem $Problem
        $said | Should -Match $Text
        $said | Should -Match 'nothing was installed'
    }

    It 'finds this computer, x64, fit' {
        $processor = Get-CimInstance -ClassName Win32_Processor -Property Architecture, AddressWidth | Select-Object -First 1
        Test-LauncherPlatform -Architecture $processor.Architecture -AddressWidth $processor.AddressWidth | Should -BeNullOrEmpty
    }

    It 'quotes the command line as Windows splits it, as the installer does' -ForEach @(
        @{ Arguments = @('-File', 'C:\app\Start-Fm350App.ps1'); Line = '-File C:\app\Start-Fm350App.ps1' }
        @{ Arguments = @('-File', 'C:\Program Files\app\Start-Fm350App.ps1', '-Hidden'); Line = '-File "C:\Program Files\app\Start-Fm350App.ps1" -Hidden' }
        @{ Arguments = @('C:\with space\'); Line = '"C:\with space\\"' }
        @{ Arguments = @(''); Line = '""' }
    ) {
        ConvertTo-LauncherCommandLine -Argument $Arguments | Should -BeExactly $Line
        ConvertTo-CommandLine -Argument $Arguments | Should -BeExactly $Line
    }

    It 'refuses an argument with a double quote' {
        { ConvertTo-LauncherCommandLine -Argument 'a"b' } | Should -Throw
        { ConvertTo-CommandLine -Argument 'a"b' -ErrorAction Stop } | Should -Throw
    }

    It 'parses and decides the same in Windows PowerShell 5.1' {
        $winps = Join-Path $script:system 'WindowsPowerShell\v1.0\powershell.exe'
        $probe = Join-Path $TestDrive 'probe.ps1'
        Set-Content -LiteralPath $probe -Value @"
. '$script:launcher'
`$list = @(
    (New-Object psobject -Property @{ Path = 'C:\Program Files\PowerShell\7\pwsh.exe'; Version = [version]'7.6.2'; SignatureValid = `$true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }),
    (New-Object psobject -Property @{ Path = 'C:\Program Files\WindowsApps\p\pwsh.exe'; Version = [version]'7.7.0'; SignatureValid = `$true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' }),
    (New-Object psobject -Property @{ Path = 'C:\Tools\pwsh.exe'; Version = [version]'7.9.0'; SignatureValid = `$true; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation' })
)
`$choice = Select-LauncherPwsh -Candidate `$list -ProgramFiles 'C:\Program Files' -Minimum ([version]'7.6.0')
`$none = Select-LauncherPwsh -Candidate @() -ProgramFiles 'C:\Program Files' -Minimum ([version]'7.6.0')
'{0}|{1}|{2}|{3}|{4}{5}' -f `$choice.Path, `$none.Problem, (ConvertTo-LauncherCommandLine -Argument @('-File', 'C:\Program Files\a b\x.ps1')), `$PSVersionTable.PSVersion.Major, (Test-LauncherPlatform -Architecture 12 -AddressWidth 64), (Test-LauncherPlatform -Architecture 9 -AddressWidth 64)
"@
        $output = & $winps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe
        $LASTEXITCODE | Should -Be 0
        $output | Should -Be 'C:\Program Files\WindowsApps\p\pwsh.exe|NotFound|-File "C:\Program Files\a b\x.ps1"|5|Arm'
    }

    It 'finds the PowerShell running these tests, when it is under Program Files' {
        $candidates = @(Get-LauncherPwshCandidate)
        $here = [Environment]::ProcessPath
        if (-not $here.StartsWith([Environment]::GetFolderPath('ProgramFiles') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-ItResult -Skipped -Because 'this PowerShell is not installed under Program Files'
            return
        }
        $mine = @($candidates | Where-Object Path -EQ $here)
        $mine.Count | Should -Be 1
        $mine[0].SignatureValid | Should -BeTrue
        $mine[0].Signer | Should -Match 'O=Microsoft Corporation'
        $mine[0].Version | Should -Be ([version]('{0}.{1}.{2}' -f $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor, $PSVersionTable.PSVersion.Patch))
    }
}

Describe 'The install layout and the tasks' {
    It 'puts everything where Windows'' known folders are' {
        $layout = Get-AppInstallLayout -ProgramFiles 'C:\Program Files' -System 'C:\WINDOWS\system32' -Programs 'C:\Users\u\Start Menu\Programs' -RoamingData 'C:\Users\u\Roaming' -LocalData 'C:\Users\u\Local'
        $layout.InstallFolder | Should -Be 'C:\Program Files\fibocom-fm350-gl-windows-gui'
        $layout.StagingFolder | Should -Be 'C:\Program Files\fibocom-fm350-gl-windows-gui.new'
        $layout.RetiredFolder | Should -Be 'C:\Program Files\fibocom-fm350-gl-windows-gui.old'
        $layout.Launcher | Should -Be 'C:\Program Files\fibocom-fm350-gl-windows-gui\Start-Fm350.ps1'
        $layout.WindowsPowerShell | Should -Be 'C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe'
        $layout.SchTasks | Should -Be 'C:\WINDOWS\system32\schtasks.exe'
        $layout.Shortcut | Should -Be 'C:\Users\u\Start Menu\Programs\Fibocom FM350-GL Windows GUI.lnk'
        $layout.Icon | Should -Be 'C:\Program Files\fibocom-fm350-gl-windows-gui\App\fibocom-fm350-gl-windows-gui.ico'
        $layout.UserData | Should -Be @('C:\Users\u\Roaming\fibocom-fm350-gl-windows-gui', 'C:\Users\u\Local\fibocom-fm350-gl-windows-gui')
        $layout.Uninstaller | Should -Be 'C:\Program Files\fibocom-fm350-gl-windows-gui\uninstall.cmd'
        $layout.CommandShell | Should -Be 'C:\WINDOWS\system32\cmd.exe'
        $layout.UninstallEntry | Should -Be 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\fibocom-fm350-gl-windows-gui'
    }

    It 'takes the known folders, not the environment the user can set' {
        $saved = $env:ProgramFiles
        try {
            $env:ProgramFiles = Join-Path $TestDrive 'not-program-files'
            (Get-AppInstallLayout).InstallFolder | Should -Be (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'fibocom-fm350-gl-windows-gui')
            (Get-AppInstallLayout).InstallFolder | Should -Not -BeLike "$TestDrive*"
        }
        finally {
            $env:ProgramFiles = $saved
        }
    }

    It 'starts the app at logon, in the tray, with no limit and on batteries too' {
        $layout = Get-AppInstallLayout -ProgramFiles 'C:\Program Files' -System 'C:\WINDOWS\system32'
        $task = New-AppTaskDefinition -Layout $layout -UserSid 'S-1-5-21-1-2-3-1001' -Kind Logon
        $task.TaskPath | Should -Be '\fibocom-fm350-gl-windows-gui\'
        $task.TaskName | Should -Be 'Start at logon'
        $task.Execute | Should -Be 'C:\WINDOWS\system32\WindowsPowerShell\v1.0\powershell.exe'
        $task.Argument | Should -BeExactly '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Program Files\fibocom-fm350-gl-windows-gui\Start-Fm350.ps1" -Hidden'
        $task.WorkingDirectory | Should -Be 'C:\WINDOWS\system32'
        $task.AtLogOn | Should -BeTrue
        $task.UserSid | Should -Be 'S-1-5-21-1-2-3-1001'
        $task.RunLevel | Should -Be 'Highest'
        $task.LogonType | Should -Be 'Interactive'
        $task.MultipleInstances | Should -Be 'IgnoreNew'
        $task.ExecutionTimeLimit | Should -Be ([timespan]::Zero) -Because 'Task Scheduler stops a task after 72 hours by default'
        $task.AllowStartIfOnBatteries | Should -BeTrue
        $task.DontStopIfGoingOnBatteries | Should -BeTrue
        $task.Priority | Should -Be 5 -Because 'the default, 7, is below normal: background work'
    }

    It 'opens the app with its window on demand, again while it runs' {
        $layout = Get-AppInstallLayout -ProgramFiles 'C:\Program Files' -System 'C:\WINDOWS\system32'
        $task = New-AppTaskDefinition -Layout $layout -UserSid 'S-1-5-21-1-2-3-1001' -Kind Open
        $task.TaskName | Should -Be 'Open'
        $task.Argument | Should -Not -Match '-Hidden$'
        $task.Argument | Should -Match '-File "C:\\Program Files\\fibocom-fm350-gl-windows-gui\\Start-Fm350.ps1"$'
        $task.AtLogOn | Should -BeFalse
        $task.MultipleInstances | Should -Be 'Parallel' -Because 'a second run brings the running app''s window up'
        $task.RunLevel | Should -Be 'Highest'
    }

    It 'refuses an account that is not a local or domain user''s' {
        $layout = Get-AppInstallLayout -ProgramFiles 'C:\Program Files' -System 'C:\WINDOWS\system32'
        { New-AppTaskDefinition -Layout $layout -UserSid 'S-1-5-18' -Kind Logon -ErrorAction Stop } | Should -Throw
    }

    It 'registers a task with Task Scheduler''s cmdlets as defined' {
        Mock -ModuleName FibocomFm350.Installer New-ScheduledTaskAction { [pscustomobject]@{ Kind = 'Action' } }
        Mock -ModuleName FibocomFm350.Installer New-ScheduledTaskPrincipal { [pscustomobject]@{ Kind = 'Principal' } }
        Mock -ModuleName FibocomFm350.Installer New-ScheduledTaskSettingsSet { [pscustomobject]@{ Kind = 'Settings' } }
        Mock -ModuleName FibocomFm350.Installer New-ScheduledTaskTrigger { [pscustomobject]@{ Kind = 'Trigger' } }
        Mock -ModuleName FibocomFm350.Installer Register-ScheduledTask { } -RemoveParameterType Action, Principal, Settings, Trigger
        $layout = Get-TestLayout
        $account = ([System.Security.Principal.SecurityIdentifier]$script:userSid).Translate([System.Security.Principal.NTAccount]).Value

        Register-AppTask -Definition (New-AppTaskDefinition -Layout $layout -UserSid $script:userSid -Kind Logon) -Confirm:$false
        Should -Invoke -ModuleName FibocomFm350.Installer New-ScheduledTaskAction -Times 1 -Exactly -ParameterFilter {
            $Execute -eq $layout.WindowsPowerShell -and $Argument -match '-File "?[^"]*Start-Fm350\.ps1"? -Hidden$' -and $WorkingDirectory -eq $layout.System
        }
        Should -Invoke -ModuleName FibocomFm350.Installer New-ScheduledTaskPrincipal -Times 1 -Exactly -ParameterFilter {
            $UserId -eq $account -and $LogonType -eq 'Interactive' -and $RunLevel -eq 'Highest'
        }
        Should -Invoke -ModuleName FibocomFm350.Installer New-ScheduledTaskSettingsSet -Times 1 -Exactly -ParameterFilter {
            $ExecutionTimeLimit -eq [timespan]::Zero -and $AllowStartIfOnBatteries -and $DontStopIfGoingOnBatteries -and $Priority -eq 5 -and $MultipleInstances -eq 'IgnoreNew' -and -not $Disable
        }
        Should -Invoke -ModuleName FibocomFm350.Installer New-ScheduledTaskTrigger -Times 1 -Exactly -ParameterFilter { $AtLogOn -and $User -eq $account }
        Should -Invoke -ModuleName FibocomFm350.Installer Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskPath -eq '\fibocom-fm350-gl-windows-gui\' -and $TaskName -eq 'Start at logon' -and $Force -and $Trigger.Kind -eq 'Trigger'
        }

        Register-AppTask -Definition (New-AppTaskDefinition -Layout $layout -UserSid $script:userSid -Kind Open) -Confirm:$false
        Should -Invoke -ModuleName FibocomFm350.Installer New-ScheduledTaskTrigger -Times 1 -Exactly -Because 'the Open task has no trigger'
        Should -Invoke -ModuleName FibocomFm350.Installer Register-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Open' -and -not $Trigger }

        Register-AppTask -Definition (New-AppTaskDefinition -Layout $layout -UserSid $script:userSid -Kind Logon -Enabled $false) -Confirm:$false
        Should -Invoke -ModuleName FibocomFm350.Installer New-ScheduledTaskSettingsSet -Times 1 -Exactly -ParameterFilter { $Disable } -Because 'a task off is registered disabled'
    }

    It 'names the logon task as the app reads it' {
        $layout = Get-TestLayout
        $app = Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -PassThru -Force
        try {
            & $app { "$script:LogonTaskPath|$script:LogonTaskName" } | Should -Be "$($layout.TaskPath)|$($layout.LogonTaskName)"
        }
        finally {
            Remove-Module -ModuleInfo $app
        }
    }

    It 'removes the app''s tasks and their folder' {
        Mock -ModuleName FibocomFm350.Installer Get-ScheduledTask {
            [pscustomobject]@{ TaskPath = '\fibocom-fm350-gl-windows-gui\'; TaskName = 'Start at logon' }
            [pscustomobject]@{ TaskPath = '\fibocom-fm350-gl-windows-gui\'; TaskName = 'Open' }
        }
        Mock -ModuleName FibocomFm350.Installer Unregister-ScheduledTask { }
        Mock -ModuleName FibocomFm350.Installer Remove-AppTaskFolder { }
        $removed = @(Unregister-AppTask -Layout (Get-TestLayout) -Confirm:$false)
        $removed | Should -Be @('\fibocom-fm350-gl-windows-gui\Start at logon', '\fibocom-fm350-gl-windows-gui\Open')
        Should -Invoke -ModuleName FibocomFm350.Installer Get-ScheduledTask -ParameterFilter { $TaskPath -eq '\fibocom-fm350-gl-windows-gui\' }
        Should -Invoke -ModuleName FibocomFm350.Installer Unregister-ScheduledTask -Times 2 -Exactly
        Should -Invoke -ModuleName FibocomFm350.Installer Remove-AppTaskFolder -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\fibocom-fm350-gl-windows-gui\' }
    }

    It 'makes the Start-menu shortcut run the Open task, minimized, with the app''s icon' {
        $layout = Get-TestLayout
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $layout.Icon) -Force)
        Set-Content -LiteralPath $layout.Icon -Value 'icon'
        New-AppShortcut -Layout $layout -Confirm:$false
        $shell = New-Object -ComObject 'WScript.Shell'
        try {
            $link = $shell.CreateShortcut($layout.Shortcut)
            $link.TargetPath | Should -Be (Join-Path $script:system 'schtasks.exe')
            $link.Arguments | Should -Be '/run /tn \fibocom-fm350-gl-windows-gui\Open'
            $link.WindowStyle | Should -Be 7
            $link.IconLocation | Should -Be "$($layout.Icon),0"
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}

Describe 'Only administrators can write' {
    It '<Name>: <Allowed>' -ForEach @(
        @{ Name = 'Program Files as Windows sets it'; Owner = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Rules = @(
                @{ Sid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'; Rights = 'FullControl' }
                @{ Sid = 'S-1-5-18'; Rights = 'Modify' }
                @{ Sid = 'S-1-5-32-544'; Rights = 'Modify' }
                @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute, Synchronize' }
                @{ Sid = 'S-1-3-0'; Rights = 'FullControl'; Propagation = 'InheritOnly' }
                @{ Sid = 'S-1-15-2-1'; Rights = 'ReadAndExecute, Synchronize' }
            ); Allowed = $true; Offenders = @()
        }
        @{ Name = 'a copy owned by Administrators, inheriting'; Owner = 'S-1-5-32-544'; Rules = @(
                @{ Sid = 'S-1-5-18'; Rights = 'FullControl' }
                @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
                @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute, Synchronize' }
            ); Allowed = $true; Offenders = @()
        }
        @{ Name = 'Users may write'; Owner = 'S-1-5-32-544'; Rules = @(
                @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
                @{ Sid = 'S-1-5-32-545'; Rights = 'Modify' }
            ); Allowed = $false; Offenders = @('S-1-5-32-545')
        }
        @{ Name = 'Authenticated Users may add files'; Owner = 'S-1-5-32-544'; Rules = @(
                @{ Sid = 'S-1-5-11'; Rights = 'CreateFiles, Synchronize' }
            ); Allowed = $false; Offenders = @('S-1-5-11')
        }
        @{ Name = 'the user may change the rules'; Owner = 'S-1-5-32-544'; Rules = @(
                @{ Sid = 'S-1-5-21-1-2-3-1001'; Rights = 'ReadAndExecute, ChangePermissions' }
            ); Allowed = $false; Offenders = @('S-1-5-21-1-2-3-1001')
        }
        @{ Name = 'owned by the user'; Owner = 'S-1-5-21-1-2-3-1001'; Rules = @(
                @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
            ); Allowed = $false; Offenders = @('owner S-1-5-21-1-2-3-1001')
        }
        @{ Name = 'a rule that denies'; Owner = 'S-1-5-32-544'; Rules = @(
                @{ Sid = 'S-1-1-0'; Rights = 'Modify'; Type = 'Deny' }
            ); Allowed = $true; Offenders = @()
        }
        @{ Name = 'a write right for everyone, inherited by children only'; Owner = 'S-1-5-32-544'; Rules = @(
                @{ Sid = 'S-1-1-0'; Rights = 'Write'; Propagation = 'InheritOnly' }
            ); Allowed = $true; Offenders = @()
        }
    ) {
        $list = @($Rules | ForEach-Object {
                $propagation = if ($_.ContainsKey('Propagation')) { $_.Propagation } else { 'None' }
                $type = if ($_.ContainsKey('Type')) { $_.Type } else { 'Allow' }
                Get-TestRule -Sid $_.Sid -Rights $_.Rights -Type $type -Propagation $propagation
            })
        $verdict = Test-AdminOnlyAccess -Owner $Owner -Rule $list
        $verdict.Allowed | Should -Be $Allowed
        @($verdict.Offenders) | Should -Be @($Offenders)
    }

    It 'finds the user''s own folder writable by the user' {
        $folder = Join-Path $TestDrive 'mine'
        [void](New-Item -ItemType Directory -Path $folder)
        Set-Content -LiteralPath (Join-Path $folder 'a.txt') -Value 'a'
        $access = Get-PathAccess -Path $folder
        $access.Owner | Should -Not -BeNullOrEmpty
        @($access.Rule | Where-Object Sid -EQ $script:userSid).Count | Should -BeGreaterThan 0
        $verdict = Test-AppFolderAccess -Path $folder
        $verdict.Allowed | Should -BeFalse
        $verdict.Offenders -join "`n" | Should -Match ([regex]::Escape('a.txt'))
    }

    It 'finds the system folder admin-only' {
        $access = Get-PathAccess -Path (Join-Path $script:system 'schtasks.exe')
        (Test-AdminOnlyAccess -Owner $access.Owner -Rule $access.Rule).Allowed | Should -BeTrue
    }
}

Describe 'The package' {
    It 'is told from any other folder' {
        Test-AppPackage -Path $script:src | Should -BeTrue
        Test-AppPackage -Path $TestDrive | Should -BeFalse
    }

    It 'is copied - its own entries, nothing else - and loses the mark of the web' {
        $package = Copy-TestPackage
        # Extracted with "extract here" into a busy folder: the folder's own files stay out.
        Set-Content -LiteralPath (Join-Path $package 'notes.txt') -Value 'mine'
        [void](New-Item -ItemType Directory -Path (Join-Path $package 'Photos'))
        Set-Content -LiteralPath (Join-Path $package 'App\Start-Fm350App.ps1') -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3"
        $destination = Join-Path $TestDrive "copy-$([guid]::NewGuid().ToString('N'))"

        $files = @(Copy-AppPackage -Source $package -Destination $destination -Confirm:$false)
        $files.Count | Should -BeGreaterThan 20
        Test-Path (Join-Path $destination 'notes.txt') | Should -BeFalse
        Test-Path (Join-Path $destination 'Photos') | Should -BeFalse
        Test-AppPackage -Path $destination | Should -BeTrue
        @(Get-Item -LiteralPath (Join-Path $destination 'App\Start-Fm350App.ps1') -Stream * | Where-Object Stream -EQ 'Zone.Identifier').Count | Should -Be 0
        (Get-ChildItem $destination -Name | Sort-Object) | Should -Be @('App', 'FibocomFm350', 'install.cmd', 'Installer', 'Start-Fm350.ps1', 'uninstall.cmd')
    }

    It 'copies lpac''s folder when the package has one' {
        $package = Copy-TestPackage
        [void](New-Item -ItemType Directory -Path (Join-Path $package 'lpac'))
        Set-Content -LiteralPath (Join-Path $package 'lpac\lpac.exe') -Value 'not a program'
        $destination = Join-Path $TestDrive "copy-$([guid]::NewGuid().ToString('N'))"
        [void](Copy-AppPackage -Source $package -Destination $destination -Confirm:$false)
        Join-Path $destination 'lpac\lpac.exe' | Should -Exist
    }

    It 'never copies into a folder that exists' {
        $destination = Join-Path $TestDrive 'exists'
        [void](New-Item -ItemType Directory -Path $destination -Force)
        { Copy-AppPackage -Source $script:src -Destination $destination -Confirm:$false -ErrorAction Stop } | Should -Throw '*exists already*'
    }
}

Describe 'Install-Fm350App' {
    BeforeAll {
        # Backstops: nothing here may reach Task Scheduler or start anything.
        Mock -ModuleName FibocomFm350.Installer Register-ScheduledTask { throw 'Register-ScheduledTask must not run in tests.' }
        Mock -ModuleName FibocomFm350.Installer Unregister-ScheduledTask { throw 'Unregister-ScheduledTask must not run in tests.' }
        Mock -ModuleName FibocomFm350.Installer Remove-AppTaskFolder { throw 'Remove-AppTaskFolder must not run in tests.' }
    }

    BeforeEach {
        $script:layout = Get-TestLayout
        $script:package = Copy-TestPackage
        $script:lock = [pscustomobject]@{ WasRunning = $false; Stopped = $true; Mutex = $null }
        Mock -ModuleName FibocomFm350.Installer Stop-AppInstance { $script:lock }
        Mock -ModuleName FibocomFm350.Installer Exit-AppInstallLock { }
        Mock -ModuleName FibocomFm350.Installer Test-AppFolderAccess { [pscustomobject]@{ Allowed = $true; Offenders = [string[]]@() } }
        Mock -ModuleName FibocomFm350.Installer Register-AppTask { }
        Mock -ModuleName FibocomFm350.Installer Start-ScheduledTask { }
        Mock -ModuleName FibocomFm350.Installer Invoke-InstalledApp { }
        Mock -ModuleName FibocomFm350.Installer Test-AppLogonTaskOn { $false }
    }

    It 'installs: the files, the two tasks, the shortcut, and starts the app' {
        $output = @(Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout)
        Test-AppPackage -Path $script:layout.InstallFolder | Should -BeTrue
        Test-Path $script:layout.StagingFolder | Should -BeFalse
        Test-Path $script:layout.RetiredFolder | Should -BeFalse
        Should -Invoke -ModuleName FibocomFm350.Installer Test-AppFolderAccess -Times 1 -Exactly -ParameterFilter { $Path -eq $script:layout.StagingFolder }
        Should -Invoke -ModuleName FibocomFm350.Installer Register-AppTask -Times 1 -Exactly -ParameterFilter { $Definition.TaskName -eq 'Start at logon' -and $Definition.UserSid -eq $script:userSid -and $Definition.Argument -match ([regex]::Escape($script:layout.Launcher)) }
        Should -Invoke -ModuleName FibocomFm350.Installer Register-AppTask -Times 1 -Exactly -ParameterFilter { $Definition.TaskName -eq 'Open' }
        Test-Path $script:layout.Shortcut | Should -BeTrue
        Should -Invoke -ModuleName FibocomFm350.Installer Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\fibocom-fm350-gl-windows-gui\' -and $TaskName -eq 'Open' }
        Should -Invoke -ModuleName FibocomFm350.Installer Exit-AppInstallLock -Times 1 -Exactly
        Should -Invoke -ModuleName FibocomFm350.Installer Invoke-InstalledApp -Times 1 -Exactly -ParameterFilter { $Failure -eq 'Install.NoIcon' }
        Should -Invoke -ModuleName FibocomFm350.Installer Invoke-InstalledApp -Times 1 -Exactly -ParameterFilter { $Failure -eq 'Install.NoIdentity' }
        Should -Invoke -ModuleName FibocomFm350.Installer Register-AppTask -Times 1 -Exactly -ParameterFilter { $Definition.TaskName -eq 'Start at logon' -and -not $Definition.Enabled } -Because 'the app doesn''t start at sign-in until the user asks'
        Should -Invoke -ModuleName FibocomFm350.Installer Register-AppTask -Times 1 -Exactly -ParameterFilter { $Definition.TaskName -eq 'Open' -and $Definition.Enabled }
        $output -join "`n" | Should -BeLike '*off: \fibocom-fm350-gl-windows-gui\Start at logon. The app''s Connection tab turns it on*'
        $output -join "`n" | Should -Match 'Installed in'
        $output -join "`n" | Should -Match 'Listed in Settings > Apps > Installed apps'
        $output[-1] | Should -Be 'The app is starting.'
    }

    It 'lists the app in Windows'' installed apps, uninstalled by its uninstall.cmd' {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        $entry = Get-ItemProperty -LiteralPath $script:layout.UninstallEntry
        $entry.DisplayName | Should -BeExactly 'Fibocom FM350-GL Windows GUI'
        $entry.DisplayVersion | Should -Be (Import-PowerShellDataFile -LiteralPath (Join-Path $script:package 'FibocomFm350\FibocomFm350.psd1')).ModuleVersion
        $entry.InstallLocation | Should -Be $script:layout.InstallFolder
        $entry.UninstallString | Should -BeExactly "`"$($script:system)\cmd.exe`" /c `"`"$($script:layout.InstallFolder)\uninstall.cmd`"`""
        $entry.URLInfoAbout | Should -Be 'https://github.com/francesco-stimola/fibocom-fm350-gl-windows-gui'
        $entry.NoModify | Should -Be 1
        $entry.NoRepair | Should -Be 1
        $entry.EstimatedSize | Should -BeGreaterThan 0
        (Get-Item -LiteralPath $script:layout.UninstallEntry).GetValueKind('EstimatedSize') | Should -Be 'DWord'
        $entry.PSObject.Properties['DisplayIcon'] | Should -BeNullOrEmpty -Because 'no icon was drawn'
        $entry.PSObject.Properties['Publisher'] | Should -BeNullOrEmpty
    }

    It 'writes the entry whole again on an update, with the icon once there is one' {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        New-ItemProperty -LiteralPath $script:layout.UninstallEntry -Name 'Stale' -Value 'x' | Out-Null
        Mock -ModuleName FibocomFm350.Installer Invoke-InstalledApp { Set-Content -LiteralPath $Layout.Icon -Value 'icon' } -ParameterFilter { $Failure -eq 'Install.NoIcon' }
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        $entry = Get-ItemProperty -LiteralPath $script:layout.UninstallEntry
        $entry.PSObject.Properties['Stale'] | Should -BeNullOrEmpty
        $entry.DisplayIcon | Should -Be $script:layout.Icon
    }

    It 'changes nothing in the list under -WhatIf' {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        Remove-Item -LiteralPath $script:layout.UninstallEntry -Recurse
        Register-AppUninstallEntry -Layout $script:layout -WhatIf
        Test-Path -LiteralPath $script:layout.UninstallEntry | Should -BeFalse
    }

    It 'keeps the start at sign-in the user turned on, on an update' {
        Mock -ModuleName FibocomFm350.Installer Test-AppLogonTaskOn { $true }
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        Should -Invoke -ModuleName FibocomFm350.Installer Register-AppTask -Times 1 -Exactly -ParameterFilter { $Definition.TaskName -eq 'Start at logon' -and $Definition.Enabled }
    }

    It 'updates: asks the running app to exit, replaces the old version whole, starts it again' {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        Set-Content -LiteralPath (Join-Path $script:layout.InstallFolder 'App\only-in-the-old-version.ps1') -Value '# old'
        Set-Content -LiteralPath (Join-Path $script:package 'App\View.ps1') -Value '# new' -NoNewline
        $script:lock = [pscustomobject]@{ WasRunning = $true; Stopped = $true; Mutex = $null }

        $output = @(Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout)
        $output[0] | Should -Match 'exited; the connection stays as it is'
        $output -join "`n" | Should -Match 'over the earlier version'
        Test-Path (Join-Path $script:layout.InstallFolder 'App\only-in-the-old-version.ps1') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:layout.InstallFolder 'App\View.ps1') -Raw | Should -Be '# new'
        Test-Path $script:layout.RetiredFolder | Should -BeFalse
        Should -Invoke -ModuleName FibocomFm350.Installer Start-ScheduledTask -Times 1 -Exactly
    }

    It 'deletes what an earlier installation left over first' {
        foreach ($leftover in $script:layout.StagingFolder, $script:layout.RetiredFolder) {
            [void](New-Item -ItemType Directory -Path (Join-Path $leftover 'App') -Force)
        }
        $output = @(Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart)
        @($output -match 'Left over').Count | Should -Be 2
        Test-AppPackage -Path $script:layout.InstallFolder | Should -BeTrue
        Test-Path $script:layout.RetiredFolder | Should -BeFalse
    }

    It 'changes nothing when the running app doesn''t exit' {
        $script:lock = [pscustomobject]@{ WasRunning = $true; Stopped = $false; Mutex = $null }
        { Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -ErrorAction Stop } | Should -Throw '*Nothing was changed*'
        Test-Path $script:layout.InstallFolder | Should -BeFalse
        Test-Path $script:layout.StagingFolder | Should -BeFalse
        Should -Invoke -ModuleName FibocomFm350.Installer Register-AppTask -Times 0 -Exactly
        Should -Invoke -ModuleName FibocomFm350.Installer Start-ScheduledTask -Times 0 -Exactly
    }

    It 'keeps the old version when the copy is not admin-only, and deletes the copy' {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        Set-Content -LiteralPath (Join-Path $script:package 'App\View.ps1') -Value '# new' -NoNewline
        Mock -ModuleName FibocomFm350.Installer Test-AppFolderAccess { [pscustomobject]@{ Allowed = $false; Offenders = [string[]]@('x: S-1-5-32-545') } }
        { Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -ErrorAction Stop } | Should -Throw '*Not only administrators*'
        Get-Content -LiteralPath (Join-Path $script:layout.InstallFolder 'App\View.ps1') -Raw | Should -Not -Be '# new'
        Test-Path $script:layout.StagingFolder | Should -BeFalse
        Should -Invoke -ModuleName FibocomFm350.Installer Register-AppTask -Times 2 -Exactly -Because 'only the first installation registered tasks'
        Should -Invoke -ModuleName FibocomFm350.Installer Exit-AppInstallLock -Times 2 -Exactly -Because 'the lock is released on failure too'
    }

    It 'puts the old version back when the new one can''t take its place' {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        $installFolder = $script:layout.InstallFolder
        Mock -ModuleName FibocomFm350.Installer Move-Item { Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop }
        Mock -ModuleName FibocomFm350.Installer Move-Item { throw 'The folder is in use.' } -ParameterFilter { $Destination -eq $installFolder -and $LiteralPath -like '*.new' }
        { Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -ErrorAction Stop } | Should -Throw '*in use*'
        Test-AppPackage -Path $script:layout.InstallFolder | Should -BeTrue
        Test-Path $script:layout.RetiredFolder | Should -BeFalse
        Test-Path $script:layout.StagingFolder | Should -BeFalse
    }

    It 'starts the app it asked to exit again when the update fails: <Name>' -ForEach @(
        @{ Name = 'the new version can''t take the old one''s place'; Fails = 'Move' }
        @{ Name = 'a task can''t be registered'; Fails = 'Task' }
    ) {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        $installFolder = $script:layout.InstallFolder
        if ($Fails -eq 'Move') {
            Mock -ModuleName FibocomFm350.Installer Move-Item { Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop }
            Mock -ModuleName FibocomFm350.Installer Move-Item { throw 'The folder is in use.' } -ParameterFilter { $Destination -eq $installFolder -and $LiteralPath -like '*.new' }
        }
        else {
            Mock -ModuleName FibocomFm350.Installer Register-AppTask { throw 'The folder is in use.' }
        }
        $script:lock = [pscustomobject]@{ WasRunning = $true; Stopped = $true; Mutex = $null }
        $output = [System.Collections.Generic.List[string]]::new()
        { Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -ErrorAction Stop | ForEach-Object { $output.Add($_) } } | Should -Throw '*in use*' -Because 'the failure is the one the installation met'
        Test-AppPackage -Path $script:layout.InstallFolder | Should -BeTrue
        Should -Invoke -ModuleName FibocomFm350.Installer Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\fibocom-fm350-gl-windows-gui\' -and $TaskName -eq 'Open' }
        Should -Invoke -ModuleName FibocomFm350.Installer Exit-AppInstallLock -Times 2 -Exactly
        $output[-1] | Should -Match 'is started again'
    }

    It 'starts nothing when the installation fails and no app was running' {
        Mock -ModuleName FibocomFm350.Installer Register-AppTask { throw 'The folder is in use.' }
        { Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -ErrorAction Stop } | Should -Throw '*in use*'
        Should -Invoke -ModuleName FibocomFm350.Installer Start-ScheduledTask -Times 0 -Exactly
    }

    It 'says so when it can''t start that app again, and still throws the installation''s failure' {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        Mock -ModuleName FibocomFm350.Installer Register-AppTask { throw 'The folder is in use.' }
        Mock -ModuleName FibocomFm350.Installer Start-ScheduledTask { throw 'The task is disabled.' }
        $script:lock = [pscustomobject]@{ WasRunning = $true; Stopped = $true; Mutex = $null }
        $output = [System.Collections.Generic.List[string]]::new()
        { Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -ErrorAction Stop | ForEach-Object { $output.Add($_) } } | Should -Throw '*in use*'
        $output[-1] | Should -Match 'couldn''t be started again \(The task is disabled\.\): start it from the Start menu'
    }

    It 'makes tasks and shortcut again when run from the install folder, without copying' {
        Install-Fm350App -Source $script:package -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        Mock -ModuleName FibocomFm350.Installer Copy-AppPackage { throw 'no copy' }
        $output = @(Install-Fm350App -Source $script:layout.InstallFolder -UserSid $script:userSid -Layout $script:layout -NoStart)
        $output -join "`n" | Should -Not -Match 'Installed in'
        Should -Invoke -ModuleName FibocomFm350.Installer Register-AppTask -Times 4 -Exactly
        Test-AppPackage -Path $script:layout.InstallFolder | Should -BeTrue
    }

    It 'refuses a folder that is not a package' {
        { Install-Fm350App -Source $TestDrive -UserSid $script:userSid -Layout $script:layout -ErrorAction Stop } | Should -Throw '*Not a package*'
        Should -Invoke -ModuleName FibocomFm350.Installer Stop-AppInstance -Times 0 -Exactly
    }

}

Describe 'The shortcut''s icon and taskbar identity' {
    BeforeAll {
        Mock -ModuleName FibocomFm350.Installer Register-ScheduledTask { throw 'Register-ScheduledTask must not run in tests.' }
        Mock -ModuleName FibocomFm350.Installer Stop-AppInstance { [pscustomobject]@{ WasRunning = $false; Stopped = $true; Mutex = $null } }
        Mock -ModuleName FibocomFm350.Installer Exit-AppInstallLock { }
        Mock -ModuleName FibocomFm350.Installer Test-AppFolderAccess { [pscustomobject]@{ Allowed = $true; Offenders = [string[]]@() } }
        Mock -ModuleName FibocomFm350.Installer Register-AppTask { }
        Mock -ModuleName FibocomFm350.Installer Start-ScheduledTask { }
    }

    It 'is drawn by the installed app, and the shortcut shows it' {
        $layout = Get-TestLayout
        Install-Fm350App -Source (Copy-TestPackage) -UserSid $script:userSid -Layout $layout -NoStart | Out-Null
        Test-Path -LiteralPath $layout.Icon | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($layout.Icon)
        [System.BitConverter]::ToUInt16($bytes, 2) | Should -Be 1 -Because 'an icon file'
        [System.BitConverter]::ToUInt16($bytes, 4) | Should -Be 8 -Because 'one image per size AppIcon.ps1 draws'
        $shell = New-Object -ComObject 'WScript.Shell'
        try {
            $link = $shell.CreateShortcut($layout.Shortcut)
            $link.IconLocation | Should -Be "$($layout.Icon),0"
            $link.Description | Should -Be 'Keeps the Fibocom FM350-GL online.'
            $link.TargetPath | Should -Be $layout.SchTasks -Because 'setting its identity keeps what it runs'
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
        # The installed app's module loaded the type that reads it.
        [FibocomFm350.AppIdentity]::GetShortcutId($layout.Shortcut) | Should -Be 'FibocomFm350Gl.WindowsGui' -Because 'the window carries the same, so pinning it pins the shortcut'
    }

    It 'goes on when the installed app can''t do its part, and says what is missing' {
        $layout = Get-TestLayout
        $warnings = & (Get-Module FibocomFm350.Installer) { param($l) Invoke-InstalledApp -Layout $l -Failure 'Install.NoIdentity' -Script { } 3>&1 } $layout
        @($warnings).Count | Should -Be 1
        [string]$warnings[0] | Should -Match 'taskbar identity'
    }
}

Describe 'Uninstall-Fm350App' {
    BeforeAll {
        Mock -ModuleName FibocomFm350.Installer Register-ScheduledTask { throw 'Register-ScheduledTask must not run in tests.' }
        Mock -ModuleName FibocomFm350.Installer Unregister-ScheduledTask { throw 'Unregister-ScheduledTask must not run in tests.' }
        Mock -ModuleName FibocomFm350.Installer Remove-AppTaskFolder { throw 'Remove-AppTaskFolder must not run in tests.' }
    }

    BeforeEach {
        $script:layout = Get-TestLayout
        $script:lock = [pscustomobject]@{ WasRunning = $false; Stopped = $true; Mutex = $null }
        Mock -ModuleName FibocomFm350.Installer Stop-AppInstance { $script:lock }
        Mock -ModuleName FibocomFm350.Installer Exit-AppInstallLock { }
        Mock -ModuleName FibocomFm350.Installer Test-AppFolderAccess { [pscustomobject]@{ Allowed = $true; Offenders = [string[]]@() } }
        Mock -ModuleName FibocomFm350.Installer Register-AppTask { }
        Mock -ModuleName FibocomFm350.Installer Start-ScheduledTask { }
        Mock -ModuleName FibocomFm350.Installer Invoke-InstalledApp { }
        Mock -ModuleName FibocomFm350.Installer Unregister-AppTask { '\fibocom-fm350-gl-windows-gui\Start at logon'; '\fibocom-fm350-gl-windows-gui\Open' }
        Install-Fm350App -Source (Copy-TestPackage) -UserSid $script:userSid -Layout $script:layout -NoStart | Out-Null
        foreach ($folder in $script:layout.UserData) {
            [void](New-Item -ItemType Directory -Path $folder -Force)
            Set-Content -LiteralPath (Join-Path $folder 'settings.json') -Value '{}'
        }
    }

    It 'removes the tasks, the shortcut and the install folder, and keeps the user''s data' {
        $script:lock = [pscustomobject]@{ WasRunning = $true; Stopped = $true; Mutex = $null }
        $output = @(Uninstall-Fm350App -Layout $script:layout)
        $output[0] | Should -Match 'the connection stays as it is'
        Should -Invoke -ModuleName FibocomFm350.Installer Unregister-AppTask -Times 1 -Exactly
        Test-Path $script:layout.Shortcut | Should -BeFalse
        Test-Path $script:layout.InstallFolder | Should -BeFalse
        Test-Path -LiteralPath $script:layout.UninstallEntry | Should -BeFalse
        $output -join "`n" | Should -Match 'Taken off Settings > Apps > Installed apps'
        foreach ($folder in $script:layout.UserData) {
            Test-Path $folder | Should -BeTrue
        }
        Should -Invoke -ModuleName FibocomFm350.Installer Exit-AppInstallLock -Times 2 -Exactly
    }

    It 'removes the settings, the secrets and the logs too when asked' {
        Uninstall-Fm350App -Layout $script:layout -RemoveUserData | Out-Null
        foreach ($folder in $script:layout.UserData) {
            Test-Path $folder | Should -BeFalse
        }
    }

    It 'changes nothing when the running app doesn''t exit' {
        $script:lock = [pscustomobject]@{ WasRunning = $true; Stopped = $false; Mutex = $null }
        { Uninstall-Fm350App -Layout $script:layout -ErrorAction Stop } | Should -Throw '*Nothing was changed*'
        Test-Path $script:layout.InstallFolder | Should -BeTrue
        Test-Path $script:layout.Shortcut | Should -BeTrue
        Test-Path -LiteralPath $script:layout.UninstallEntry | Should -BeTrue
        Should -Invoke -ModuleName FibocomFm350.Installer Unregister-AppTask -Times 0 -Exactly
    }

    It 'keeps the entry while the folder can''t be removed, so the uninstallation can run again from the list' {
        Mock -ModuleName FibocomFm350.Installer Remove-AppFolder { throw 'The folder is in use.' }
        { Uninstall-Fm350App -Layout $script:layout -ErrorAction Stop } | Should -Throw '*in use*'
        Test-Path -LiteralPath $script:layout.UninstallEntry | Should -BeTrue
    }

    It 'takes the entry off when the folder was removed only in part, and what it runs is gone: <Gone>' -ForEach @(
        @{ Gone = 'Installer' }
        @{ Gone = 'uninstall.cmd' }
    ) {
        $gone = Join-Path $script:layout.InstallFolder $Gone
        Mock -ModuleName FibocomFm350.Installer Remove-AppFolder { Remove-Item -LiteralPath $gone -Recurse -Force; throw 'The folder is in use.' }
        { Uninstall-Fm350App -Layout $script:layout -ErrorAction Stop } | Should -Throw '*in use*' -Because 'the failure is still said'
        Test-Path -LiteralPath $script:layout.UninstallEntry | Should -BeFalse
    }

    It 'has nothing to remove a second time' {
        Uninstall-Fm350App -Layout $script:layout | Out-Null
        Mock -ModuleName FibocomFm350.Installer Unregister-AppTask { }
        @(Uninstall-Fm350App -Layout $script:layout) | Should -BeNullOrEmpty
    }
}

Describe 'Stop-AppInstance' {
    BeforeEach {
        $script:name = "fm350-test-$([guid]::NewGuid().ToString('N'))"
    }

    It 'holds the mutex when no app runs, and lets it go' {
        $lock = Stop-AppInstance -Name $script:name -Confirm:$false
        try {
            $lock.WasRunning | Should -BeFalse
            $lock.Stopped | Should -BeTrue
            $lock.Mutex | Should -Not -BeNullOrEmpty
        }
        finally {
            Exit-AppInstallLock -Lock $lock
        }
        $again = Stop-AppInstance -Name $script:name -Confirm:$false
        $again.WasRunning | Should -BeFalse
        Exit-AppInstallLock -Lock $again
    }

    It 'asks a running app to exit through its exit event, and waits for it' {
        $name = $script:name
        $holder = Start-ThreadJob -ScriptBlock {
            $mutex = [System.Threading.Mutex]::new($true, "Global\$using:name")
            $exit = [System.Threading.EventWaitHandle]::new($false, 'AutoReset', "Local\$using:name-exit")
            $asked = $exit.WaitOne(20000)
            Start-Sleep -Milliseconds 300
            $mutex.ReleaseMutex()
            $mutex.Dispose()
            $exit.Dispose()
            $asked
        }
        try {
            $deadline = [Environment]::TickCount64 + 10000
            $existing = $null
            while (-not [System.Threading.EventWaitHandle]::TryOpenExisting("Local\$name-exit", [ref]$existing) -and [Environment]::TickCount64 -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            if ($existing) { $existing.Dispose() }
            $lock = Stop-AppInstance -Name $name -TimeoutMs 15000 -Confirm:$false
            try {
                $lock.WasRunning | Should -BeTrue
                $lock.Stopped | Should -BeTrue
            }
            finally {
                Exit-AppInstallLock -Lock $lock
            }
            $holder | Wait-Job -Timeout 20 | Receive-Job | Should -BeTrue -Because 'the app was asked through its exit event'
        }
        finally {
            $holder | Remove-Job -Force
        }
    }

    It 'gives up on an app that doesn''t exit' {
        $name = $script:name
        $ready = Join-Path $TestDrive "$name.ready"
        $finish = Join-Path $TestDrive "$name.finish"
        $holder = Start-ThreadJob -ScriptBlock {
            $mutex = [System.Threading.Mutex]::new($true, "Global\$using:name")
            New-Item -Path $using:ready | Out-Null
            while (-not (Test-Path $using:finish)) { Start-Sleep -Milliseconds 50 }
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
        try {
            $deadline = [Environment]::TickCount64 + 10000
            while (-not (Test-Path $ready) -and [Environment]::TickCount64 -lt $deadline) {
                Start-Sleep -Milliseconds 50
            }
            $lock = Stop-AppInstance -Name $name -TimeoutMs 500 -Confirm:$false
            $lock.WasRunning | Should -BeTrue
            $lock.Stopped | Should -BeFalse
            $lock.Mutex | Should -BeNullOrEmpty
        }
        finally {
            New-Item -Path $finish | Out-Null
            $holder | Wait-Job -Timeout 10 | Remove-Job -Force
        }
    }

    It 'makes the real app exit, its connection left as it is' {
        $local = Join-Path $TestDrive 'local'
        $logs = Join-Path $local 'fibocom-fm350-gl-windows-gui\simulated\logs'
        $start = Join-Path $script:src 'App\Start-Fm350App.ps1'
        $process = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList '-NoProfile', '-File', "`"$start`"", '-Simulated', '-Scenario', 'Connect', '-Hidden' `
            -Environment @{ LOCALAPPDATA = $local } -PassThru -WindowStyle Hidden
        try {
            $deadline = [Environment]::TickCount64 + 60000
            $online = $false
            while (-not $online -and [Environment]::TickCount64 -lt $deadline) {
                Start-Sleep -Milliseconds 200
                $online = [bool](@(Get-ChildItem -Path $logs -Filter '*.log' -ErrorAction SilentlyContinue | Get-Content) -match 'State \(start\) -> Online')
            }
            $online | Should -BeTrue
            $lock = Stop-AppInstance -Name 'fibocom-fm350-gl-windows-gui-simulated' -TimeoutMs 30000 -Confirm:$false
            try {
                $lock.WasRunning | Should -BeTrue
                $lock.Stopped | Should -BeTrue
            }
            finally {
                Exit-AppInstallLock -Lock $lock
            }
            $process.WaitForExit(15000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
        }
        finally {
            if (-not $process.HasExited) {
                $process.Kill()
            }
        }
        $log = @(Get-ChildItem -Path $logs -Filter '*.log' | Get-Content)
        $log -match 'Asked to exit by the installer' | Should -Not -BeNullOrEmpty
        $log -match 'Worker 1 stopped' | Should -Not -BeNullOrEmpty
        $log -match 'App stopped' | Should -Not -BeNullOrEmpty
        $log -match 'ERROR' | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-Fm350Setup.ps1' {
    It 'does nothing when the UAC prompt was answered by another account' {
        $setup = Join-Path $script:src 'Installer\Invoke-Fm350Setup.ps1'
        $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $setup -Action Install -UserSid 'S-1-5-21-1-2-3-1001' -NoPause
        $LASTEXITCODE | Should -Be 1
        # Not elevated, it stops at the rights; elevated (CI), at the account - said in Windows'
        # display language, as the setup window says it.
        [void](Set-SetupLanguage)
        try {
            $either = @('Setup.NeedsAdmin', 'Setup.OtherAccount' | ForEach-Object { [regex]::Escape((Get-SetupText 'Setup.Failed' (Get-SetupText $_))) }) -join '|'
            $output -join "`n" | Should -Match $either
        }
        finally {
            [void](Set-SetupLanguage -Culture 'en')
        }
    }
}
