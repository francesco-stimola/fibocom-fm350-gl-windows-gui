# The app's languages: the one chosen for each Windows display language; every table complete -
# the same keys as English, the same placeholders, saved as UTF-8 with a byte order mark -; every
# key the code and the window's XAML name is in English, and every English key is used; each
# language shown on every simulated scenario and in the window, with no key missing; the settings'
# issues said in English as the log says them; the installer's and the launcher's texts the same
# way, and read right by Windows PowerShell 5.1.

BeforeDiscovery {
    $script:languages = @('it', 'de', 'fr', 'es', 'pt', 'nl', 'pl')
    $script:tables = foreach ($component in 'App', 'Installer') {
        foreach ($language in @('en') + $script:languages) {
            @{ Component = $component; Language = $language }
        }
    }
}

BeforeAll {
    Import-Module "$PSScriptRoot/../src/FibocomFm350/FibocomFm350.psd1" -Force
    Import-Module "$PSScriptRoot/../src/App/FibocomFm350.App.psd1" -Force
    Import-Module "$PSScriptRoot/../src/Installer/FibocomFm350.Installer.psd1" -Force
    $script:src = (Resolve-Path "$PSScriptRoot/../src").Path

    # A table's path, and its texts.
    function Get-TablePath {
        param([string] $Component, [string] $Language)
        Join-Path $script:src "$Component\Strings\$Language.psd1"
    }
    function Get-Table {
        param([string] $Component, [string] $Language)
        Import-PowerShellDataFile -LiteralPath (Get-TablePath -Component $Component -Language $Language) -SkipLimitCheck
    }
    # The placeholders of a text, as a sorted list.
    function Get-Placeholder {
        param([string] $Text)
        (@([regex]::Matches($Text, '\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',')
    }
    # The snapshot the worker publishes after one cycle on a simulated scenario.
    function Get-ScenarioSnapshot {
        param([string] $Scenario)
        $link = New-ModemWorkerLink
        $worker = New-ModemWorker -Link $link -Simulation (New-SimulatedDevice -Scenario $Scenario) -DataFolder (Join-Path $TestDrive ([guid]::NewGuid()))
        try {
            Invoke-ModemWorkerCycle -Worker $worker
            $link['Snapshot']
        }
        finally {
            Close-ModemWorker -Worker $worker
            Close-ModemWorkerLink -Link $link
        }
    }
    # A key no table had, as Get-AppText shows it.
    $script:missing = '\[[A-Z][A-Za-z]+\.[A-Za-z0-9.]+\]'
}

AfterAll {
    [void](Set-AppLanguage -Culture 'en')
    Remove-Module FibocomFm350.Installer, FibocomFm350.App, FibocomFm350 -ErrorAction SilentlyContinue
}

Describe 'The language of the app' {
    It 'speaks <Language> for <Culture>' -ForEach @(
        @{ Culture = 'it-IT'; Language = 'it' }
        @{ Culture = 'it-CH'; Language = 'it' }
        @{ Culture = 'de-DE'; Language = 'de' }
        @{ Culture = 'de-AT'; Language = 'de' }
        @{ Culture = 'fr-FR'; Language = 'fr' }
        @{ Culture = 'fr-CA'; Language = 'fr' }
        @{ Culture = 'es-ES'; Language = 'es' }
        @{ Culture = 'es-MX'; Language = 'es' }
        @{ Culture = 'pt-PT'; Language = 'pt' }
        @{ Culture = 'pt-BR'; Language = 'pt' }
        @{ Culture = 'nl-NL'; Language = 'nl' }
        @{ Culture = 'nl-BE'; Language = 'nl' }
        @{ Culture = 'pl-PL'; Language = 'pl' }
        @{ Culture = 'pl'; Language = 'pl' }
        @{ Culture = 'en-GB'; Language = 'en' }
        @{ Culture = 'sv-SE'; Language = 'en' }
        @{ Culture = 'ja-JP'; Language = 'en' }
        @{ Culture = ''; Language = 'en' }
        @{ Culture = 'not a culture'; Language = 'en' }
    ) {
        Resolve-AppLanguage -Culture $Culture | Should -Be $Language
        Resolve-SetupLanguage -Culture $Culture | Should -Be $Language
    }

    It 'speaks Windows'' display language by default' {
        Set-AppLanguage | Should -Be (Resolve-AppLanguage -Culture ([System.Globalization.CultureInfo]::CurrentUICulture.Name))
        [void](Set-AppLanguage -Culture 'en')
    }

    It 'speaks English where a language''s table can''t be read' {
        $app = Get-Module FibocomFm350.App
        $texts = & $app { Read-AppTextTable -Language 'xx' }
        $texts['Tone.Online'] | Should -Be 'Online'
    }

    It 'fills placeholders in the invariant culture, and shows a key it has no text for' {
        $saved = [System.Globalization.CultureInfo]::CurrentCulture
        try {
            [System.Globalization.CultureInfo]::CurrentCulture = 'it-IT'
            Get-AppText 'Window.Modems' -Arguments ([double]1.5), 'COM7' | Should -Be '1.5 modems found: the app uses the one on COM7.'
        }
        finally {
            [System.Globalization.CultureInfo]::CurrentCulture = $saved
        }
        Get-AppText 'No.SuchKey' | Should -Be '[No.SuchKey]'
        Get-AppText 'Result.AttemptsLeft' 0 | Should -Be 'Attempts left: 0.' -Because 'a single 0 is an argument too'
    }
}

Describe 'The tables' {
    It '<Component> <Language>: UTF-8 with a byte order mark' -ForEach $script:tables {
        $bytes = [System.IO.File]::ReadAllBytes((Get-TablePath -Component $Component -Language $Language))
        [System.BitConverter]::ToString($bytes, 0, 3) | Should -Be 'EF-BB-BF' -Because 'Windows PowerShell 5.1 reads a file without one in the ANSI code page'
        { [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) } | Should -Not -Throw
    }

    It '<Component> <Language>: the keys of English, each text with its placeholders' -ForEach $script:tables {
        $english = Get-Table -Component $Component -Language 'en'
        $table = Get-Table -Component $Component -Language $Language
        @($english.Keys | Where-Object { -not $table.ContainsKey($_) }) | Should -BeNullOrEmpty -Because 'every key has a text'
        @($table.Keys | Where-Object { -not $english.ContainsKey($_) }) | Should -BeNullOrEmpty -Because 'no key is unknown'
        foreach ($key in $english.Keys) {
            $table[$key] | Should -Not -BeNullOrEmpty -Because "$key has a text"
            Get-Placeholder $table[$key] | Should -Be (Get-Placeholder $english[$key]) -Because "$key keeps its placeholders"
            # A brace that is no placeholder breaks the formatting.
            ($table[$key] -replace '\{\d+\}', '') | Should -Not -Match '[{}]' -Because "$key has no stray brace"
            { [string]::Format([cultureinfo]::InvariantCulture, $table[$key], [object[]]@('a', 'b', 'c', 'd', 'e', 'f')) } | Should -Not -Throw
        }
    }

    It '<Language>: a text after a colon starts in lower case, where the language does' -ForEach @(
        @{ Language = 'en' }, @{ Language = 'it' }, @{ Language = 'fr' }, @{ Language = 'es' }, @{ Language = 'pt' }, @{ Language = 'nl' }, @{ Language = 'pl' }
    ) {
        $table = Get-Table -Component 'App' -Language $Language
        foreach ($key in @($table.Keys | Where-Object { $_ -like '*Inline.*' })) {
            $table[$key].Substring(0, 1) | Should -BeExactly $table[$key].Substring(0, 1).ToLower() -Because "$key follows a colon"
        }
    }
}

Describe 'The keys the code uses' {
    BeforeAll {
        $script:english = Get-Table -Component 'App' -Language 'en'
        $script:prefixes = @($script:english.Keys | ForEach-Object { $_.Split('.')[0] } | Sort-Object -Unique)
        $script:code = (Get-ChildItem -Path (Join-Path $script:src 'App') -Filter '*.ps1' | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $script:xaml = Get-Content -LiteralPath (Join-Path $script:src 'App\MainWindow.xaml') -Raw
    }

    It 'has an English text for every key the code names' {
        $named = @([regex]::Matches($script:code, "'(([A-Z][A-Za-z]+)\.[A-Za-z0-9.]+)'") | Where-Object { $_.Groups[2].Value -in $script:prefixes } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $named.Count | Should -BeGreaterThan 100
        @($named | Where-Object { -not $script:english.ContainsKey($_) }) | Should -BeNullOrEmpty
    }

    It 'has an English text for every key the window''s XAML names' {
        $named = @([regex]::Matches($script:xaml, '\[\[([A-Za-z0-9.]+)\]\]') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $named.Count | Should -BeGreaterThan 40
        @($named | Where-Object { -not $script:english.ContainsKey($_) }) | Should -BeNullOrEmpty
    }

    It 'uses every English key: by name, or by a family the code completes with a code' {
        # "Reason.$reason", "Esim.State.$state"...: families keyed by the snapshot's codes.
        $families = @([regex]::Matches($script:code, '"([A-Z][A-Za-z]+(?:\.[A-Z][A-Za-z]+)*)\.\$') | ForEach-Object { "$($_.Groups[1].Value)." } | Sort-Object -Unique)
        $named = @([regex]::Matches($script:code + $script:xaml, "(?:'|\[\[)([A-Z][A-Za-z]+\.[A-Za-z0-9.]+)(?:'|\]\])") | ForEach-Object { $_.Groups[1].Value })
        $unused = @($script:english.Keys | Where-Object {
                $key = $_
                $key -notin $named -and -not @($families | Where-Object { $key.StartsWith($_) }) -and $key -notin 'Dns.LookedUpNext', 'Dns.LookedUpOperatorNext'
            })
        $unused | Should -BeNullOrEmpty
    }
}

Describe 'Each language on the screen' {
    BeforeAll {
        $script:snapshots = foreach ($scenario in 'Online', 'Connect', 'ApnNeeded', 'PinRequired', 'FccLocked', 'AdapterDisabled', 'NoDevice', 'NoDriver', 'DataPathDown', 'Unrecoverable', 'LteOnlyMode', 'NrOnlyMode') {
            Get-ScenarioSnapshot -Scenario $scenario
        }
    }

    AfterEach {
        [void](Set-AppLanguage -Culture 'en')
    }

    It '<_>: every scenario in words, no key missing, the tooltip within 127 characters' -ForEach $script:languages {
        Set-AppLanguage -Culture $_ | Should -Be $_
        foreach ($snapshot in $script:snapshots) {
            foreach ($worker in 'Running', 'Restarting', 'NotResponding') {
                $view = ConvertTo-WindowView -Snapshot $snapshot -Worker $worker
                ($view | ConvertTo-Json -Depth 6) | Should -Not -Match $script:missing
                $tip = ConvertTo-TrayText -Snapshot $snapshot -Worker $worker
                $tip | Should -Not -Match $script:missing
                $tip.Length | Should -BeLessOrEqual 127
                (Get-TrayModeMenu -Snapshot $snapshot -Worker $worker | ConvertTo-Json -Depth 4) | Should -Not -Match $script:missing
            }
        }
        (ConvertTo-WindowView -Snapshot $script:snapshots[0]).Detail | Should -Not -Be 'Connected.' -Because 'the window speaks the language'
    }

    It '<_>: the window loads with its texts, and saves values, not the words it shows' -ForEach $script:languages {
        [void](Set-AppLanguage -Culture $_)
        $script:sent = [System.Collections.Generic.List[object]]::new()
        $window = New-MainWindow -Send { param($kind, $parameter) $script:sent.Add([pscustomobject]@{ Kind = $kind; Parameter = $parameter }) }
        try {
            $window.Controls.SaveSettingsButton.Content | Should -Not -BeNullOrEmpty
            $window.Controls.SaveSettingsButton.Content | Should -Not -Match '\[\['
            $window.Controls.ConnectionTab.Header | Should -Be (Get-AppText 'Xaml.ConnectionTab')
            Update-MainWindow -View (ConvertTo-WindowView -Snapshot $script:snapshots[0])
            $window.Controls.AuthenticationBox.SelectedItem.Content | Should -Be (Get-AppText 'Xaml.AuthNone')
            $window.Controls.SaveSettingsButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            $window.Controls.SettingsProblemText.Text | Should -BeNullOrEmpty
            $script:sent[0].Parameter.Settings.ApnAuthentication | Should -Be 'None'
            $script:sent[0].Parameter.Settings.PdpType | Should -Be 'IPV4V6'
        }
        finally {
            $window.Exiting = $true
            $window.Window.Close()
        }
    }

    It '<_>: every rule a setting can break, in words' -ForEach $script:languages {
        [void](Set-AppLanguage -Culture $_)
        $app = Get-Module FibocomFm350.App
        foreach ($rule in 'Text', 'TextQuotes', 'OneOf', 'EmptyOrOneOf', 'Addresses', 'Number', 'Minutes', 'Bool', 'Https', 'Bands', 'Unknown', 'Unreadable', 'DohNeedsServers', 'TemplateAddress', 'Gigabytes') {
            $issue = [pscustomobject]@{ Setting = 'InterfaceMetric'; Rule = $rule; Values = [object[]]@(1, 9999) }
            & $app { param($i) ConvertTo-SettingIssueText -Issue $i } $issue | Should -Not -Match $script:missing
        }
    }
}

Describe 'The settings'' issues in English' {
    It 'says each as the log does: <_>' -ForEach @(
        @{ Apn = ' x' }, @{ PdpType = 'PPP' }, @{ ApnUser = 'a"b' }, @{ DnsServers = 53 }, @{ InterfaceMetric = 0 }, @{ NetworkMode = 'x' }
        @{ DnsOverHttps = 'yes' }, @{ DohRefreshMinutes = 1 }, @{ DohTemplate = 'http://x' }, @{ LteBands = @(0) }, @{ Colour = 'blue' }
        @{ DnsOverHttps = $true }, @{ DnsServers = @('203.0.113.53', '203.0.113.54'); DohTemplate = 'https://203.0.113.53/q' }
    ) {
        $checked = ConvertTo-AppSetting -InputObject $_
        $checked.Issues.Count | Should -Be $checked.Problems.Count
        $app = Get-Module FibocomFm350.App
        for ($i = 0; $i -lt $checked.Issues.Count; $i++) {
            & $app { param($issue) ConvertTo-SettingIssueText -Issue $issue } $checked.Issues[$i] | Should -Be $checked.Problems[$i]
        }
    }
}

Describe 'The installer''s and the launcher''s languages' {
    AfterEach {
        [void](Set-SetupLanguage -Culture 'en')
    }

    It '<_>: every text, and yes in its words' -ForEach $script:languages {
        Set-SetupLanguage -Culture $_ | Should -Be $_
        foreach ($key in (Get-Table -Component 'Installer' -Language 'en').Keys) {
            Get-SetupText $key 'a' 'b' | Should -Not -Match $script:missing
        }
        $yes = "^\s*(y|yes|$(Get-SetupText 'Setup.Yes'))\s*$"
        'y' | Should -Match $yes
        'n' | Should -Not -Match $yes
        '' | Should -Not -Match $yes -Because 'no is the default'
        (Get-SetupText 'Setup.AskUserData') | Should -Match '\[[^\]]+/N\]$'
    }

    It '<_>: names the tray menu''s Exit as the tray does' -ForEach (@('en') + $script:languages) {
        $exit = (Get-Table -Component 'App' -Language $_)['Tray.Exit']
        (Get-Table -Component 'Installer' -Language $_)['Install.StillRunning'] | Should -BeLike "*$exit*"
    }

    It 'takes the Italian yes' {
        [void](Set-SetupLanguage -Culture 'it-IT')
        $yes = "^\s*(y|yes|$(Get-SetupText 'Setup.Yes'))\s*$"
        foreach ($answer in 's', 'si', "s$([char]0xEC)", ' S ') {
            $answer | Should -Match $yes
        }
    }

    It 'reads the accents right in Windows PowerShell 5.1, as the launcher does' {
        $winps = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
        $probe = Join-Path $TestDrive 'probe.ps1'
        Set-Content -LiteralPath $probe -Value @"
. '$(Join-Path $script:src 'Start-Fm350.ps1')'
`$language = Set-SetupLanguage -Culture 'it-IT'
`$text = (Get-LauncherProblemText -Problem 'Arm') + '|' + `$language
[Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(`$text))
"@
        $output = & $winps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe
        $LASTEXITCODE | Should -Be 0
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($output)) | Should -BeExactly ((Get-Table -Component 'Installer' -Language 'it')['Launcher.Arm'] + '|it')
    }
}
