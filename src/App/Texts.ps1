# The app's texts in the user's language (ARCHITECTURE -> Languages): one table per language in
# Strings\<language>.psd1, English the full one and the fallback of the others. The language is
# Windows' display language, chosen when the app starts (Set-AppLanguage); until then, and in the
# tests, English. The log stays in English.

# The languages the app speaks, English first.
$script:AppLanguages = @('en', 'it', 'de', 'fr', 'es', 'pt', 'nl', 'pl')

function Resolve-AppLanguage {
    <#
    .SYNOPSIS
        The language the app speaks for a Windows display language.
    .DESCRIPTION
        A pure decision: -Culture (a culture name such as 'it-CH') or its parents ('it') among
        -Available; English when none is.
    .EXAMPLE
        Resolve-AppLanguage -Culture 'de-AT' -Available 'en', 'de'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Culture,

        [string[]] $Available = $script:AppLanguages
    )

    $info = $null
    try {
        $info = [System.Globalization.CultureInfo]::GetCultureInfo($Culture)
    }
    catch [System.Globalization.CultureNotFoundException] {
        return 'en'
    }
    while ($info -and $info.Name) {
        if ($info.Name -in $Available) {
            return $info.Name
        }
        $info = $info.Parent
    }
    'en'
}

function Read-AppTextTable {
    # The texts of one language, English underneath: a key a language lacks reads in English, and
    # a language whose table can't be read is English - it never stops the app.
    param([string] $Language)

    $folder = Join-Path -Path $PSScriptRoot -ChildPath 'Strings'
    # More than the 500 keys a data file may hold by default: the app's own tables, installed where
    # only administrators write.
    $texts = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $folder -ChildPath 'en.psd1') -SkipLimitCheck
    if ($Language -and $Language -ne 'en') {
        try {
            $own = Import-PowerShellDataFile -LiteralPath (Join-Path -Path $folder -ChildPath "$Language.psd1") -SkipLimitCheck -ErrorAction Stop
            foreach ($key in $own.Keys) {
                $texts[$key] = $own[$key]
            }
        }
        catch {
            Write-Verbose "The texts in '$Language' can't be read, English is used: $($_.Exception.Message)"
        }
    }
    $texts
}

function Set-AppLanguage {
    <#
    .SYNOPSIS
        Makes the app speak the language of -Culture, Windows' display language by default.
    .DESCRIPTION
        Among the languages the app has (Resolve-AppLanguage); English otherwise. Returns the
        language chosen.
    .EXAMPLE
        Set-AppLanguage -Culture 'it-IT'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the module''s texts in memory; changes no system state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string] $Culture = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    )

    $language = Resolve-AppLanguage -Culture $Culture
    $script:Texts = Read-AppTextTable -Language $language
    $script:Language = $language
    $language
}

function Get-AppText {
    <#
    .SYNOPSIS
        One of the app's texts, in its language, with its placeholders filled.
    .DESCRIPTION
        -Arguments fill {0}, {1}... in the invariant culture: numbers are written as the app
        writes them everywhere. A key no table has reads as itself in brackets, so it shows -
        the tests prove there is none.
    .EXAMPLE
        Get-AppText -Key 'Tray.Tooltip' -Arguments 'Online'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Key,

        # Positional too: Get-AppText 'Key' $first $second.
        [Parameter(Position = 1, ValueFromRemainingArguments)]
        [AllowNull()]
        [object[]] $Arguments
    )

    $template = $script:Texts[$Key]
    if ($null -eq $template) {
        return "[$Key]"
    }
    # (Not "if ($Arguments)": an array of one 0 or '' is false.)
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $template, $Arguments)
    }
    $template
}

function Test-AppText {
    # Whether the app has a text for -Key.
    param([string] $Key)

    $script:Texts.ContainsKey($Key)
}

function ConvertTo-LocalizedXaml {
    # The window's XAML with each [[Key]] replaced by its text, escaped for XML.
    param([string] $Xaml)

    $Xaml -replace '\[\[([A-Za-z0-9.]+)\]\]', { [System.Security.SecurityElement]::Escape((Get-AppText -Key $_.Groups[1].Value)) }
}

$script:Texts = Read-AppTextTable -Language 'en'
$script:Language = 'en'
