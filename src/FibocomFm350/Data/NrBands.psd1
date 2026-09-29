# NR frequency raster and downlink NR-ARFCN ranges per band, FR1: 3GPP TS 38.101-1 V20.1.0
# (38101-1-k10), Table 5.4.2.1-1 (F_REF = F_REF-Offs + dF_Global (N_REF - N_REF-Offs), clause
# 5.4.2.1) and Table 5.4.2.3-1. A band's range is the union of its raster rows (first to last,
# steps not kept); supplementary-uplink bands, which have no downlink, are left out. Ranges
# overlap between bands (n77 and n78, for instance): a channel can belong to several.
@{
    Source = '3GPP TS 38.101-1 V20.1.0, Tables 5.4.2.1-1 and 5.4.2.3-1'
    Raster = @(
        @{ First = 0; Last = 599999; StepKHz = 5; OffsetMHz = 0; OffsetArfcn = 0 }
        @{ First = 600000; Last = 2016666; StepKHz = 15; OffsetMHz = 3000; OffsetArfcn = 600000 }
    )
    Bands  = @(
        @{ Band = 1; First = 422000; Last = 434000 }
        @{ Band = 2; First = 386000; Last = 398000 }
        @{ Band = 3; First = 361000; Last = 376000 }
        @{ Band = 5; First = 173800; Last = 178800 }
        @{ Band = 7; First = 524000; Last = 538000 }
        @{ Band = 8; First = 185000; Last = 192000 }
        @{ Band = 12; First = 145800; Last = 149200 }
        @{ Band = 13; First = 149200; Last = 151200 }
        @{ Band = 14; First = 151600; Last = 153600 }
        @{ Band = 18; First = 172000; Last = 175000 }
        @{ Band = 20; First = 158200; Last = 164200 }
        @{ Band = 24; First = 305000; Last = 311800 }
        @{ Band = 25; First = 386000; Last = 399000 }
        @{ Band = 26; First = 171800; Last = 178800 }
        @{ Band = 28; First = 151600; Last = 160600 }
        @{ Band = 29; First = 143400; Last = 145600 }
        @{ Band = 30; First = 470000; Last = 472000 }
        @{ Band = 31; First = 92500; Last = 93500 }
        @{ Band = 34; First = 402000; Last = 405000 }
        @{ Band = 38; First = 514000; Last = 524000 }
        @{ Band = 39; First = 376000; Last = 384000 }
        @{ Band = 40; First = 460000; Last = 480000 }
        @{ Band = 41; First = 499200; Last = 537999 }
        @{ Band = 46; First = 743334; Last = 795000 }
        @{ Band = 47; First = 790334; Last = 795000 }
        @{ Band = 48; First = 636667; Last = 646666 }
        @{ Band = 50; First = 286400; Last = 303400 }
        @{ Band = 51; First = 285400; Last = 286400 }
        @{ Band = 53; First = 496700; Last = 499000 }
        @{ Band = 54; First = 334000; Last = 335000 }
        @{ Band = 65; First = 422000; Last = 440000 }
        @{ Band = 66; First = 422000; Last = 440000 }
        @{ Band = 67; First = 147600; Last = 151600 }
        @{ Band = 68; First = 150600; Last = 156600 }
        @{ Band = 70; First = 399000; Last = 404000 }
        @{ Band = 71; First = 123400; Last = 130400 }
        @{ Band = 72; First = 92200; Last = 93200 }
        @{ Band = 74; First = 295000; Last = 303600 }
        @{ Band = 75; First = 286400; Last = 303400 }
        @{ Band = 76; First = 285400; Last = 286400 }
        @{ Band = 77; First = 620000; Last = 680000 }
        @{ Band = 78; First = 620000; Last = 653333 }
        @{ Band = 79; First = 693334; Last = 733333 }
        @{ Band = 85; First = 145600; Last = 149200 }
        @{ Band = 87; First = 84000; Last = 85000 }
        @{ Band = 88; First = 84400; Last = 85400 }
        @{ Band = 90; First = 499200; Last = 538000 }
        @{ Band = 91; First = 285400; Last = 286400 }
        @{ Band = 92; First = 286400; Last = 303400 }
        @{ Band = 93; First = 285400; Last = 286400 }
        @{ Band = 94; First = 286400; Last = 303400 }
        @{ Band = 96; First = 795000; Last = 875000 }
        @{ Band = 100; First = 183880; Last = 185000 }
        @{ Band = 101; First = 380000; Last = 382000 }
        @{ Band = 102; First = 795000; Last = 828333 }
        @{ Band = 104; First = 828334; Last = 875000 }
        @{ Band = 105; First = 122400; Last = 130400 }
        @{ Band = 106; First = 187000; Last = 188000 }
        @{ Band = 109; First = 286400; Last = 303400 }
        @{ Band = 110; First = 286400; Last = 287000 }
        @{ Band = 115; First = 295180; Last = 302180 }
    )
}
