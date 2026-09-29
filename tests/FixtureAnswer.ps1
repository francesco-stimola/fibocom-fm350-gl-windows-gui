# Test helper, dot-sourced by the parser tests: plays a fixture through the simulated modem and
# the AT channel, and returns the answer lines as Invoke-AtCommand delivers them to a parser.

function Get-FixtureAnswer {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    $fixture = Import-AtFixture -Path (Join-Path -Path $PSScriptRoot -ChildPath "fixtures/documented/$Name")
    $channel = New-AtChannel -Transport (New-SimulatedModem -Fixture $fixture)
    try {
        [void](Initialize-AtChannel -Channel $channel -TimeoutMs 1000)
        $answer = Invoke-AtCommand -Channel $channel -Command $fixture.Command -TimeoutMs 1000
        if ($answer.Status -ne 'OK') {
            throw "Fixture '$Name' answered $($answer.Status) through the channel."
        }
        , $answer.Lines
    }
    finally {
        Close-AtChannel -Channel $channel
    }
}
