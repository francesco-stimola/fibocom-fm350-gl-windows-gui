# The only identifier-like values a fixture may carry (docs/SETUP.md -> Fixtures).
# tests/Fixtures.Tests.ps1 fails on any other value in these places.
@{
    # Any run of 14 or more digits: IMEI (15), IMSI (15), ICCID (19-20), EID (32).
    LongNumbers  = @(
        '000000000000000'                   # IMEI
        '001010000000001'                   # IMSI on the 3GPP test network, MCC 001 / MNC 01
        '8900100000000000000'               # ICCID, 19 digits
        '89001000000000000000'              # ICCID, 20 digits
        '89001000000000000000000000000000'  # EID, 32 digits
    )

    # The module serial number, quoted in +CFSN answers.
    SerialNumbers = @('0000000000')

    # Quoted phone numbers ("+" optional, 7 digits or more).
    PhoneNumbers = @(
        '+10000000000'
        '10000000000'
    )

    # Location: the TAC and cell identity of registration reports (+CREG, +CGREG, +CEREG,
    # +C5GREG) and of +GTCCINFO cell lines, in hexadecimal and in decimal, padded to the lengths
    # the FM350 uses (TAC 4 or 6 digits, cell identity 8, 9 or 10).
    Tac          = @('ABCD', '00ABCD', '43981')
    CellId       = @('0ABCDEF0', 'ABCDEF0', '00ABCDEF0', '000ABCDEF0', '180150000')

    # The modem's "not known" location pattern (all F after leading zeros, or all zeros) is no
    # identifier and stays as captured.
    LocationNotKnown = '^0*F*$'

    # PnP instance IDs (USB\<device ID>\<instance>): the instance part is the USB serial number,
    # one of SerialNumbers above, or a Windows-generated '<n>&<hash>&<n>&<port>' with this hash.
    InstanceIdHash = '00000000'

    # Windows container IDs.
    ContainerIds = @('{00000000-0000-0000-0000-000000000001}', '{00000000-0000-0000-0000-000000000002}')
}
