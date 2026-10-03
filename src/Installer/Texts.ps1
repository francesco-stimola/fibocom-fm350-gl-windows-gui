# The texts of the installer and of the launcher in the user's language (ARCHITECTURE ->
# Languages): one table per language in Strings\<language>.psd1, English the full one and the
# fallback of the others; the language is Windows' display language (Set-SetupLanguage), English
# until it is set. The installer module and the launcher both dot-source this file, so it is
# written for Windows PowerShell 5.1 too: no syntax or member that PowerShell 7 added.

# The languages the installer speaks, English first; and where their tables are.
$script:SetupLanguages = @('en', 'it', 'de', 'fr', 'es', 'pt', 'nl', 'pl')
$script:SetupTextFolder = [IO.Path]::Combine($PSScriptRoot, 'Strings')

function Resolve-SetupLanguage {
    <#
    .SYNOPSIS
        The language the installer speaks for a Windows display language.
    .DESCRIPTION
        A pure decision: -Culture (a culture name such as 'it-CH') or its parents ('it') among
        -Available; English when none is.
    .EXAMPLE
        Resolve-SetupLanguage -Culture 'de-AT'
    #>
    param([string] $Culture, [string[]] $Available = $script:SetupLanguages)

    $info = $null
    try {
        $info = [System.Globalization.CultureInfo]::GetCultureInfo($Culture)
    }
    catch [System.Globalization.CultureNotFoundException] {
        return 'en'
    }
    while ($info -and $info.Name) {
        if ($Available -contains $info.Name) {
            return $info.Name
        }
        $info = $info.Parent
    }
    'en'
}

function Set-SetupLanguage {
    <#
    .SYNOPSIS
        Makes the installer and the launcher speak the language of -Culture.
    .DESCRIPTION
        Windows' display language by default, when the installer has it (Resolve-SetupLanguage);
        English underneath, for a key a language lacks, and instead of a language whose table
        can't be read. Returns the language chosen.
    .EXAMPLE
        Set-SetupLanguage -Culture 'it-IT'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes the texts in memory; changes no system state.')]
    param([string] $Culture = [System.Globalization.CultureInfo]::CurrentUICulture.Name)

    $language = Resolve-SetupLanguage -Culture $Culture
    $texts = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:SetupTextFolder, 'en.psd1'))
    if ($language -ne 'en') {
        try {
            $own = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:SetupTextFolder, "$language.psd1")) -ErrorAction Stop
            foreach ($key in $own.Keys) {
                $texts[$key] = $own[$key]
            }
        }
        catch {
            Write-Verbose "The texts in '$language' can't be read, English is used: $($_.Exception.Message)"
            $language = 'en'
        }
    }
    $script:SetupTexts = $texts
    $language
}

function Get-SetupText {
    <#
    .SYNOPSIS
        One of the installer's texts, in its language, with its placeholders filled.
    .DESCRIPTION
        -Arguments fill {0}, {1}... in the invariant culture. A key no table has reads as itself
        in brackets, so it shows - the tests prove there is none.
    .EXAMPLE
        Get-SetupText 'Install.Copied' 42
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Key,

        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [AllowNull()]
        [object[]] $Arguments
    )

    $template = $script:SetupTexts[$Key]
    if ($null -eq $template) {
        return "[$Key]"
    }
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $template, $Arguments)
    }
    $template
}

$script:SetupTexts = Import-PowerShellDataFile -LiteralPath ([IO.Path]::Combine($script:SetupTextFolder, 'en.psd1'))
