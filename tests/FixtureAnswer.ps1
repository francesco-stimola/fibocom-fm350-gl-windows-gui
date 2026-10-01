# Test helpers, dot-sourced by the parser tests: play a fixture through the simulated modem and the
# AT channel, and return what Invoke-AtCommand delivers. Fixtures are read from
# tests/fixtures/<Folder>: 'documented' by default, 'device' for captures.

function Get-FixtureResult {
    # The whole answer object: Status, Lines, ErrorCode...
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [ValidateSet('documented', 'device')]
        [string] $Folder = 'documented'
    )

    $fixture = Import-AtFixture -Path (Join-Path -Path $PSScriptRoot -ChildPath "fixtures/$Folder/$Name")
    $channel = New-AtChannel -Transport (New-SimulatedModem -Fixture $fixture)
    try {
        [void](Initialize-AtChannel -Channel $channel -TimeoutMs 5000)
        Invoke-AtCommand -Channel $channel -Command $fixture.Command -TimeoutMs 5000
    }
    finally {
        Close-AtChannel -Channel $channel
    }
}

function Get-FixtureAnswer {
    # The answer lines of a fixture that ends in OK, as a parser receives them.
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [ValidateSet('documented', 'device')]
        [string] $Folder = 'documented'
    )

    $answer = Get-FixtureResult -Name $Name -Folder $Folder
    if ($answer.Status -ne 'OK') {
        throw "Fixture '$Folder/$Name' answered $($answer.Status) through the channel."
    }
    , $answer.Lines
}
