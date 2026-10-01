# The simulated FM350 of development mode (New-SimulatedDevice). The answers are the device's own
# layouts (tests/fixtures/device) with the fixtures' fake values: operator 001/01, documentation
# addresses (RFC 5737), the fake ICCID, TAC and cell identity of tests/fixtures/fakes.psd1.
@{
    # A modem registered with an EN-DC cell, its SIM ready and its PIN request off, the app's
    # context active on the operator's internet APN: every scenario starts from these.
    Answers   = @{
        'AT+CPIN?'                                            = @('+CPIN: READY', 'OK')
        'AT+ICCID'                                            = @('+ICCID: 8900100000000000000f', 'OK')
        'AT+CPINR'                                            = @('+CME ERROR: 100')
        'AT+EPINC?'                                           = @('+EPINC: 3, 3, 10, 10', 'OK')
        'AT+CLCK="SC",2'                                      = @('+CLCK: 0', 'OK')
        'AT+CFUN?'                                            = @('+CFUN: 1', 'OK')
        'AT+CEREG?;+C5GREG?'                                  = @('+CEREG: 0,1', '+C5GREG: 0', 'OK')
        'AT+COPS?'                                            = @('+COPS:0,2,"00101",13', 'OK')
        'AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?' = @('+GTFCCLOCKMODE: 0', '+GTFCCLOCKSTATE: 0', '+GTFCCEFFSTATUS: 0,1', 'OK')
        'AT+CGDCONT?'                                         = @('+CGDCONT: 0,"IPV4V6","","",0,0,0,2,1,1,,0,1,0', '+CGDCONT: 1,"IPV4V6","","",0,0,0,0,0,0,,0,0,0', 'OK')
        'AT+CGACT?'                                           = @('+CGACT: 1,1', 'OK')
        'AT+CGCONTRDP=1'                                      = @('+CGCONTRDP: 1,6,"internet.mnc001.mcc001.gprs","","","192.0.2.53","192.0.2.54","","",0,,1500,,,,,,,,,,,,0', 'OK')
        'AT+CGPADDR=1'                                        = @('+CGPADDR: 1,"192.0.2.10",""', 'OK')
        'AT+CGAUTH?'                                          = @('+CGAUTH: 0,0,"",""', 'OK')
        'AT+CESQ'                                             = @('+CESQ: 99,99,255,255,14,44,40,49,69', 'OK')
        'AT+GTCCINFO?;+GTCAINFO?'                             = @(
            '+GTCCINFO:'
            '1,4,001,01,ABCD,00ABCDEF0,1850,123,103,100,4,44,44,13'
            '1,9,,,FFFFFFF,00FFFFFFF,645312,130,5078,400,2,49,49,69'
            '2,4,,,FFFF,00FFFFFFF,1850,137,,41,41,71'
            '+GTCAINFO:'
            'PCC:5078,130,645312,400,400,2,1,1,3,-107'
            'PCC:103,123,1850,100,100,1,1,3,1,-95'
            'SCC 1:2,1,101,144,525,75,50,1,1,3,3,-95'
            'SCC 2:2,0,107,151,3025,75,255,1,255,3,255,-95'
            'OK'
        )
    }

    # Each scenario changes the base:
    # - Answers: standing answers that differ from the base ones.
    # - Then: command -> the answers it changes once it has run ('Base': the base answer; a
    #   command mapped to 'Base' itself brings every answer back to the base). The command is
    #   answered OK.
    # - Vanish: commands after which the modem drops off USB (a restart), back a few seconds later.
    # - Adapter: 'Configured' (as the app would leave it), 'Fresh' (DHCP on, link-local
    #   address) or 'Disabled' (fresh, and disabled by the user).
    # - Presence: how PnP sees the modem - 'Present', 'Absent' or 'NoDriver'.
    Scenarios = @{
        # Online: the app attaches and changes nothing.
        Online          = @{
            Adapter = 'Configured'
        }

        # A registered modem with no context yet: defined, activated, the adapter configured.
        Connect         = @{
            Adapter = 'Fresh'
            Answers = @{
                'AT+CGDCONT?' = @('+CGDCONT: 0,"IPV4V6","","",0,0,0,2,1,1,,0,1,0', 'OK')
                'AT+CGACT?'   = @('OK')
            }
            Then    = @{
                'AT+CGDCONT=1,"IPV4V6",""' = @{ 'AT+CGDCONT?' = 'Base' }
                'AT+CGACT=1,1'             = @{ 'AT+CGACT?' = 'Base' }
            }
        }

        # An empty APN put on the IMS APN by the network: the app asks for an APN. The simulated
        # network takes 'internet' (PDP type IPV4V6).
        ApnNeeded       = @{
            Adapter = 'Fresh'
            Answers = @{
                'AT+CGCONTRDP=1' = @('+CGCONTRDP: 1,6,"ims.mnc001.mcc001.gprs","","","192.0.2.53","","","",0,,1500,,,,,,,,,,,,0', 'OK')
                'AT+CGPADDR=1'   = @('+CGPADDR: 1,"0.0.0.0.0.0.0.0.32.1.13.184.0.0.0.1",""', 'OK')
            }
            Then    = @{
                'AT+CGACT=0,1'                     = @{ 'AT+CGACT?' = @('OK') }
                'AT+CGDCONT=1,"IPV4V6","internet"' = @{ 'AT+CGDCONT?' = @('+CGDCONT: 0,"IPV4V6","","",0,0,0,2,1,1,,0,1,0', '+CGDCONT: 1,"IPV4V6","internet","",0,0,0,0,0,0,,0,0,0', 'OK') }
                'AT+CGACT=1,1'                     = @{ 'AT+CGACT?' = 'Base'; 'AT+CGCONTRDP=1' = 'Base'; 'AT+CGPADDR=1' = 'Base' }
            }
        }

        # A SIM waiting for its PIN, its PIN request on: the PIN is 1234; 0000 is refused.
        PinRequired     = @{
            Adapter = 'Configured'
            Answers = @{
                'AT+CPIN?'        = @('+CPIN: SIM PIN', 'OK')
                'AT+CLCK="SC",2'  = @('+CLCK: 1', 'OK')
                'AT+CPIN="0000"'  = @('+CME ERROR: 16')
            }
            Then    = @{
                'AT+CPIN="1234"'         = @{ 'AT+CPIN?' = 'Base' }
                'AT+CLCK="SC",0,"1234"'  = @{ 'AT+CLCK="SC",2' = 'Base' }
            }
        }

        # A module locked by a laptop's maker (the reads of fixtures/documented/fcc.locked.txt):
        # its radio stays off. The unlock restarts it, unlocked and online.
        FccLocked       = @{
            Adapter = 'Fresh'
            Answers = @{
                'AT+CFUN?'                                            = @('+CFUN: 4', 'OK')
                'AT+CFUN=1'                                           = @('+CME ERROR: 0')
                'AT+CEREG?;+C5GREG?'                                  = @('+CEREG: 0,0', '+C5GREG: 0', 'OK')
                'AT+COPS?'                                            = @('+COPS:0,255,"",0', 'OK')
                'AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?' = @('+GTFCCLOCKMODE: 2', '+GTFCCLOCKSTATE: 0', '+GTFCCEFFSTATUS: 2,0', 'OK')
                'AT+CGDCONT?'                                         = @('OK')
                'AT+CGACT?'                                           = @('OK')
                'AT+CESQ'                                             = @('+CESQ: 99,99,255,255,255,255,255,255,255', 'OK')
                'AT+GTCCINFO?;+GTCAINFO?'                             = @('+GTCCINFO:', 'OK')
            }
            Then    = @{
                'AT+GTFCCLOCKMODE=0'  = @{}
                'AT+GTFCCLOCKSTATE=0' = @{}
                'AT&W'                = @{}
                'AT+CFUN=1,1'         = 'Base'
            }
            Vanish  = @('AT+CFUN=1,1')
        }

        # The modem's network adapter disabled by the user: the app asks before enabling it.
        AdapterDisabled = @{
            Adapter = 'Disabled'
        }

        # No modem on USB.
        NoDevice        = @{
            Presence = 'Absent'
        }

        # The modem on USB, its AT port without a driver.
        NoDriver        = @{
            Presence = 'NoDriver'
        }
    }
}
