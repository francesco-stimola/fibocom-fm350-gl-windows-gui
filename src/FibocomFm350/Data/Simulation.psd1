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
        'AT+CGACT=0,1'                                        = @('OK')
        'AT+CGACT=1,1'                                        = @('OK')
        'AT+COPS=2'                                           = @('OK')
        'AT+COPS=0'                                           = @('OK')
        'AT+CFUN=4'                                           = @('OK')
        'AT+CFUN=1'                                           = @('OK')
        'AT+CFUN=15'                                          = @('OK')
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

    # The network mode (AT+GTACT, AT-COMMANDS section 5): what the modem supports and keeps - the
    # device's lists, automatic mode with every band but n77, which it drops once it has tried to
    # register when n78 is listed too - and the network around it: LTE cells on B1, B3, B7 and
    # B20, NR on n78 under EN-DC, no 5G SA. Its answers when registered on LTE or on 5G SA, while
    # searching, and its radio on EN-DC (the base answers), LTE alone, 5G SA, and nothing.
    NetworkMode = @{
        Rat          = 20
        Preferences  = @('6', '3')
        Supported    = @{
            UMTS = @(1, 2, 4, 5, 8)
            LTE  = @(101, 102, 103, 104, 105, 107, 108, 112, 113, 114, 117, 118, 119, 120, 125, 126, 128, 129, 130, 132, 134, 138, 139, 140, 141, 142, 143, 146, 148, 166, 171)
            NR   = @(501, 502, 503, 505, 507, 508, 5020, 5025, 5028, 5030, 5038, 5040, 5041, 5048, 5066, 5071, 5077, 5078, 5079)
        }
        Bands        = @{
            UMTS = @(1, 2, 4, 5, 8)
            LTE  = @(101, 102, 103, 104, 105, 107, 108, 112, 113, 114, 117, 118, 119, 120, 125, 126, 128, 129, 130, 132, 134, 138, 139, 140, 141, 142, 143, 146, 148, 166, 171)
            NR   = @(501, 502, 503, 505, 507, 508, 5020, 5025, 5028, 5030, 5038, 5040, 5041, 5048, 5066, 5071, 5078, 5079)
        }
        Dropped      = @{ 5077 = 5078 }
        NetworkLte   = @(101, 103, 107, 120)
        NetworkNr    = @(5078)
        Standalone   = $false
        Registration = @{
            Lte       = @('+CEREG: 0,1', '+C5GREG: 0', 'OK')
            Sa        = @('+CEREG: 0,0', '+C5GREG: 0,1', 'OK')
            Searching = @('+CEREG: 0,2', '+C5GREG: 0', 'OK')
        }
        Radio        = @{
            Lte  = @{
                'AT+CESQ'                 = @('+CESQ: 99,99,255,255,14,44,255,255,255', 'OK')
                'AT+GTCCINFO?;+GTCAINFO?' = @(
                    '+GTCCINFO:'
                    '1,4,001,01,ABCD,00ABCDEF0,1850,123,103,100,4,44,44,13'
                    '2,4,,,FFFF,00FFFFFFF,1850,137,,41,41,71'
                    '+GTCAINFO:'
                    'PCC:103,123,1850,100,100,1,1,3,1,-95'
                    'SCC 1:2,1,101,144,525,75,50,1,1,3,3,-95'
                    'SCC 2:2,0,107,151,3025,75,255,1,255,3,255,-95'
                    'OK'
                )
            }
            Sa   = @{
                'AT+CESQ'                 = @('+CESQ: 99,99,255,255,255,255,40,49,69', 'OK')
                'AT+GTCCINFO?;+GTCAINFO?' = @(
                    '+GTCCINFO:'
                    '1,9,001,01,00ABCD,000ABCDEF0,645312,130,5078,400,2,49,49,69'
                    '+GTCAINFO:'
                    'PCC:5078,130,645312,400,400,2,1,1,3,-107'
                    'OK'
                )
            }
            None = @{
                'AT+CESQ'                 = @('+CESQ: 99,99,255,255,255,255,255,255,255', 'OK')
                'AT+GTCCINFO?;+GTCAINFO?' = @('+GTCCINFO:', 'OK')
            }
        }
    }

    # What the recovery steps and the steps that follow them do, every time they succeed: the
    # answers they change ('Base': the base answer; 'Answers = Base': every answer back to the
    # base), the device flags they set (DataPath), and whether the modem drops off USB.
    Transitions = @{
        # R2, then the pass: a context restarted mends a data path that was down.
        'AT+CGACT=0,1' = @{ Answers = @{ 'AT+CGACT?' = @('OK') }; Flags = @{ DataPath = 'Up' } }
        'AT+CGACT=1,1' = @{ Answers = @{ 'AT+CGACT?' = 'Base' } }
        # R3, then the pass: deregistered, the context goes with the registration.
        'AT+COPS=2'    = @{ Answers = @{ 'AT+COPS?' = @('+COPS: 2', 'OK'); 'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,0', '+C5GREG: 0', 'OK'); 'AT+CGACT?' = @('OK') } }
        'AT+COPS=0'    = @{ Answers = @{ 'AT+COPS?' = 'Base'; 'AT+CEREG?;+C5GREG?' = 'Base' } }
        # R4, then the pass: the radio off leaves the registration unknown (stat 4), no context.
        'AT+CFUN=4'    = @{ Answers = @{ 'AT+CFUN?' = @('+CFUN: 4', 'OK'); 'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,4', '+C5GREG: 0', 'OK'); 'AT+CGACT?' = @('OK') } }
        'AT+CFUN=1'    = @{ Answers = @{ 'AT+CFUN?' = 'Base'; 'AT+CEREG?;+C5GREG?' = 'Base' } }
        # R5: the modem resets - off USB, back with every answer as in the base.
        'AT+CFUN=15'   = @{ Answers = 'Base'; Flags = @{ DataPath = 'Up' }; Vanish = $true }
    }

    # The messages on its SIM (AT-COMMANDS section 9), SMS-DELIVER PDUs from the fixtures' fake
    # service centre and senders: one read, from a name; one unread from a number, in UCS2 with an
    # emoji; a long one in two parts, unread. And one that comes in AfterMs after the modem starts.
    # Status: 0 unread, 1 read.
    Messages = @{
        Stored   = @(
            @{ Status = 1; Pdu = '07910100000000F0040ED04F78591EA6BFE500006201409000008049D7327BFC6E9743202A3A3D07B5CBF379F85C068DDFEDF21C6496BFDB203ABA0C9AA7DB7576985E2683DA6F72B90D7A9B41E4B2BDCC7EC3DB65371DD47E93CB2E' }
            @{ Status = 0; Pdu = '07910100000000F0040B910100000000F000086201400103008048004300690061006F002100200049006C0020006D006F00640065006D002000730069006D0075006C00610074006F002000740069002000730061006C0075007400610020D83DDC4B' }
            @{ Status = 0; Pdu = '07910100000000F04407D049B7F90D000062014011150080A00500032A0201B2EFBA1C440ED3C32071DD4D669741F2B2BB7C9F83DE6E101D5D0699D3F2391D440EE7416F33888E2E83DA6F371DED0251D1E939885EC6D341E93988FD769F4165F7BB7E4683E86F90BB5C2683E8F737081E96D3E72CD01D9D1EA3417474191486C341EA77DA3D0789C3E33528EDA6BF416F7719D42ECFE7E17399054ABB416F39B92C6781C4' }
            @{ Status = 0; Pdu = '07910100000000F04407D049B7F90D000062014011150080180500032A0202CAE6B7BC0C9AA3DFF7B4FB0C4AD35D' }
        )
        Arrivals = @(
            @{ AfterMs = 60000; Pdu = '07910100000000F00407D049B7F90D0000620140214365806ED9771D840EDBCBA0FABC4C06E16025D0DB0CCABFEB7210394C0F83C47537995D7681504150BB3C9F87CF65101D5D06CDD3ED3A3B4C2F9341ED37B9DC06C9CBE372DA5E9E83C220769A4E6797416133BD2C07D1D16550180E07CDE961397DEE4A01' }
        )
    }

    # Each scenario changes the base:
    # - Like: another scenario this one starts from.
    # - Answers: standing answers that differ from the base ones.
    # - Then: command -> the answers it changes the first time it has run ('Base': the base
    #   answer; a command mapped to 'Base' itself brings every answer back to the base). The
    #   command is answered OK.
    # - Vanish: commands after which the modem drops off USB (a restart), back a few seconds later.
    # - Transitions: what recovery commands do here, instead of the base's (above).
    # - Flags: the device's flags at the start (DataPath 'Down': no traffic gets through).
    # - Hung: the AT port answers nothing until the USB device is restarted.
    # - Adapter: 'Configured' (as the app would leave it), 'Fresh' (DHCP on, link-local
    #   address) or 'Disabled' (fresh, and disabled by the user). DadChecks: probes that find an
    #   address just set still being checked by Windows. LostRounds: probe rounds lost after it.
    #   PassedRounds: probe rounds that pass before a path that is down shows it.
    # - Presence: how PnP sees the modem - 'Present', 'Absent' or 'NoDriver'.
    # - NetworkMode: what differs from the base network mode (above), or the network around it.
    # - Messages: the messages on its SIM instead of the base ones (above).
    # The SIM slots (AT-COMMANDS section 8): slot 0 the physical SIM in use, slot 1 an eUICC holding
    # one profile of class test, disabled - as our module has them. Profiles: Aid, Iccid (the
    # fixtures' fakes), State, Nickname, Provider, Name, Class.
    Esim      = @{
        Slot     = 0
        Profiles = @(
            @{ Aid = 'A0000005591010FFFFFFFF8900002000'; Iccid = '8900100000000000001'; State = 'Disabled'; Nickname = ''; Provider = 'Example Lab'; Name = 'Lab test profile'; Class = 'Test' }
        )
    }

    Scenarios = @{
        # Online: the app attaches and changes nothing.
        Online           = @{
            Adapter = 'Configured'
        }

        # A registered modem with no context yet: defined, activated, the adapter configured. Its
        # SIM holds no message: nothing to announce while connecting.
        Connect          = @{
            Adapter  = 'Fresh'
            Messages = @{ Stored = @(); Arrivals = @() }
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
        ApnNeeded        = @{
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
        PinRequired      = @{
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
        FccLocked        = @{
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
        AdapterDisabled  = @{
            Adapter = 'Disabled'
        }

        # No modem on USB.
        NoDevice         = @{
            Presence = 'Absent'
        }

        # The modem on USB, its AT port without a driver.
        NoDriver         = @{
            Presence = 'NoDriver'
        }

        # As Connect, and the path settles: the new address is not usable for two probes, then a
        # round is lost. None of it is a failure.
        Settling         = @{
            Like       = 'Connect'
            DadChecks  = 2
            LostRounds = 1
        }

        # Online, the path proven once, then no traffic gets through; restarting the context (R2)
        # mends it.
        DataPathDown     = @{
            Adapter      = 'Configured'
            Flags        = @{ DataPath = 'Down' }
            PassedRounds = 1
        }

        # Online, and no probe ever answered: a network that drops ICMP. Nothing is escalated.
        IcmpDropped      = @{
            Adapter = 'Configured'
            Flags   = @{ DataPath = 'Down' }
        }

        # Not registered: re-registering (R3) doesn't help, the radio off and on (R4) does.
        RegistrationLost = @{
            Adapter     = 'Configured'
            Answers     = @{
                'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,2', '+C5GREG: 0', 'OK')
                'AT+COPS?'           = @('+COPS: 0', 'OK')
                'AT+CGACT?'          = @('OK')
            }
            Transitions = @{
                'AT+COPS=0' = @{ Answers = @{ 'AT+COPS?' = @('+COPS: 0', 'OK') } }
            }
        }

        # The AT port answers nothing until the USB device is restarted (R6).
        ModemHung        = @{
            Adapter = 'Configured'
            Hung    = $true
        }

        # The modem in LTE-only mode, set before the app: online on LTE, left so until the user
        # chooses a mode.
        LteOnlyMode      = @{
            Adapter     = 'Configured'
            NetworkMode = @{ Rat = 2; Preferences = @('3', '3') }
        }

        # The modem in NR-only mode, where there is no 5G SA network: it finds none. Choosing
        # 4G + 5G brings it online.
        NrOnlyMode       = @{
            Adapter     = 'Fresh'
            Answers     = @{ 'AT+CGACT?' = @('OK') }
            NetworkMode = @{ Rat = 14; Preferences = @('6', '6') }
        }

        # A network with 5G SA on n78: in NR-only mode the modem registers on it.
        Standalone       = @{
            Adapter     = 'Configured'
            NetworkMode = @{ Standalone = $true }
        }

        # The eUICC's slot in use, no profile enabled (+CPIN: EMPTY_EUICC): the user enables one.
        EsimEmpty        = @{
            Adapter = 'Fresh'
            Answers = @{ 'AT+CGACT?' = @('OK') }
            Esim    = @{ Slot = 1 }
        }

        # The eUICC's slot in use, an operational profile enabled and online, the test profile
        # beside it.
        Esim             = @{
            Adapter = 'Configured'
            Esim    = @{
                Slot     = 1
                Profiles = @(
                    @{ Aid = 'A0000005591010FFFFFFFF8900002000'; Iccid = '8900100000000000001'; State = 'Disabled'; Nickname = ''; Provider = 'Example Lab'; Name = 'Lab test profile'; Class = 'Test' }
                    @{ Aid = 'A0000005591010FFFFFFFF8900001000'; Iccid = '89001000000000000000'; State = 'Enabled'; Nickname = 'Travel'; Provider = 'Example Mobile'; Name = 'Example plan'; Class = 'Operational' }
                )
            }
        }

        # The network refuses the registration, whatever is done.
        Unrecoverable    = @{
            Adapter     = 'Configured'
            Answers     = @{
                'AT+CEREG?;+C5GREG?' = @('+CEREG: 0,3', '+C5GREG: 0', 'OK')
                'AT+COPS?'           = @('+COPS: 0', 'OK')
                'AT+CGACT?'          = @('OK')
            }
            Transitions = @{
                'AT+COPS=2'  = @{ Answers = @{ 'AT+COPS?' = @('+COPS: 2', 'OK') } }
                'AT+COPS=0'  = @{ Answers = @{ 'AT+COPS?' = @('+COPS: 0', 'OK') } }
                'AT+CFUN=4'  = @{ Answers = @{ 'AT+CFUN?' = @('+CFUN: 4', 'OK') } }
                'AT+CFUN=1'  = @{ Answers = @{ 'AT+CFUN?' = 'Base' } }
                'AT+CFUN=15' = @{ Vanish = $true }
            }
        }
    }
}
