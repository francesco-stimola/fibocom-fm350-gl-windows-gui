# E-UTRA downlink channel numbers: 3GPP TS 36.101 V20.1.0 (36101-k10), Table 5.7.3-1.
# F_DL = F_DL_low + 0.1 (N_DL - N_Offs-DL), clause 5.7.3. Downlink columns only; bands
# without a downlink ("Reserved") are left out. Extracted from the specification's tables and
# checked: every range starts at its N_Offs-DL, and no two ranges overlap.
@{
    Source = '3GPP TS 36.101 V20.1.0, Table 5.7.3-1'
    Bands  = @(
        @{ Band = 1; FdlLowMHz = 2110; NOffsDl = 0; First = 0; Last = 599 }
        @{ Band = 2; FdlLowMHz = 1930; NOffsDl = 600; First = 600; Last = 1199 }
        @{ Band = 3; FdlLowMHz = 1805; NOffsDl = 1200; First = 1200; Last = 1949 }
        @{ Band = 4; FdlLowMHz = 2110; NOffsDl = 1950; First = 1950; Last = 2399 }
        @{ Band = 5; FdlLowMHz = 869; NOffsDl = 2400; First = 2400; Last = 2649 }
        @{ Band = 6; FdlLowMHz = 875; NOffsDl = 2650; First = 2650; Last = 2749 }
        @{ Band = 7; FdlLowMHz = 2620; NOffsDl = 2750; First = 2750; Last = 3449 }
        @{ Band = 8; FdlLowMHz = 925; NOffsDl = 3450; First = 3450; Last = 3799 }
        @{ Band = 9; FdlLowMHz = 1844.9; NOffsDl = 3800; First = 3800; Last = 4149 }
        @{ Band = 10; FdlLowMHz = 2110; NOffsDl = 4150; First = 4150; Last = 4749 }
        @{ Band = 11; FdlLowMHz = 1475.9; NOffsDl = 4750; First = 4750; Last = 4949 }
        @{ Band = 12; FdlLowMHz = 729; NOffsDl = 5010; First = 5010; Last = 5179 }
        @{ Band = 13; FdlLowMHz = 746; NOffsDl = 5180; First = 5180; Last = 5279 }
        @{ Band = 14; FdlLowMHz = 758; NOffsDl = 5280; First = 5280; Last = 5379 }
        @{ Band = 17; FdlLowMHz = 734; NOffsDl = 5730; First = 5730; Last = 5849 }
        @{ Band = 18; FdlLowMHz = 860; NOffsDl = 5850; First = 5850; Last = 5999 }
        @{ Band = 19; FdlLowMHz = 875; NOffsDl = 6000; First = 6000; Last = 6149 }
        @{ Band = 20; FdlLowMHz = 791; NOffsDl = 6150; First = 6150; Last = 6449 }
        @{ Band = 21; FdlLowMHz = 1495.9; NOffsDl = 6450; First = 6450; Last = 6599 }
        @{ Band = 22; FdlLowMHz = 3510; NOffsDl = 6600; First = 6600; Last = 7399 }
        @{ Band = 23; FdlLowMHz = 2180; NOffsDl = 7500; First = 7500; Last = 7699 }
        @{ Band = 24; FdlLowMHz = 1525; NOffsDl = 7700; First = 7700; Last = 8039 }
        @{ Band = 25; FdlLowMHz = 1930; NOffsDl = 8040; First = 8040; Last = 8689 }
        @{ Band = 26; FdlLowMHz = 859; NOffsDl = 8690; First = 8690; Last = 9039 }
        @{ Band = 27; FdlLowMHz = 852; NOffsDl = 9040; First = 9040; Last = 9209 }
        @{ Band = 28; FdlLowMHz = 758; NOffsDl = 9210; First = 9210; Last = 9659 }
        @{ Band = 29; FdlLowMHz = 717; NOffsDl = 9660; First = 9660; Last = 9769 }
        @{ Band = 30; FdlLowMHz = 2350; NOffsDl = 9770; First = 9770; Last = 9869 }
        @{ Band = 31; FdlLowMHz = 462.5; NOffsDl = 9870; First = 9870; Last = 9919 }
        @{ Band = 32; FdlLowMHz = 1452; NOffsDl = 9920; First = 9920; Last = 10359 }
        @{ Band = 33; FdlLowMHz = 1900; NOffsDl = 36000; First = 36000; Last = 36199 }
        @{ Band = 34; FdlLowMHz = 2010; NOffsDl = 36200; First = 36200; Last = 36349 }
        @{ Band = 35; FdlLowMHz = 1850; NOffsDl = 36350; First = 36350; Last = 36949 }
        @{ Band = 36; FdlLowMHz = 1930; NOffsDl = 36950; First = 36950; Last = 37549 }
        @{ Band = 37; FdlLowMHz = 1910; NOffsDl = 37550; First = 37550; Last = 37749 }
        @{ Band = 38; FdlLowMHz = 2570; NOffsDl = 37750; First = 37750; Last = 38249 }
        @{ Band = 39; FdlLowMHz = 1880; NOffsDl = 38250; First = 38250; Last = 38649 }
        @{ Band = 40; FdlLowMHz = 2300; NOffsDl = 38650; First = 38650; Last = 39649 }
        @{ Band = 41; FdlLowMHz = 2496; NOffsDl = 39650; First = 39650; Last = 41589 }
        @{ Band = 42; FdlLowMHz = 3400; NOffsDl = 41590; First = 41590; Last = 43589 }
        @{ Band = 43; FdlLowMHz = 3600; NOffsDl = 43590; First = 43590; Last = 45589 }
        @{ Band = 44; FdlLowMHz = 703; NOffsDl = 45590; First = 45590; Last = 46589 }
        @{ Band = 45; FdlLowMHz = 1447; NOffsDl = 46590; First = 46590; Last = 46789 }
        @{ Band = 46; FdlLowMHz = 5150; NOffsDl = 46790; First = 46790; Last = 54539 }
        @{ Band = 47; FdlLowMHz = 5855; NOffsDl = 54540; First = 54540; Last = 55239 }
        @{ Band = 48; FdlLowMHz = 3550; NOffsDl = 55240; First = 55240; Last = 56739 }
        @{ Band = 49; FdlLowMHz = 3550; NOffsDl = 56740; First = 56740; Last = 58239 }
        @{ Band = 50; FdlLowMHz = 1432; NOffsDl = 58240; First = 58240; Last = 59089 }
        @{ Band = 51; FdlLowMHz = 1427; NOffsDl = 59090; First = 59090; Last = 59139 }
        @{ Band = 52; FdlLowMHz = 3300; NOffsDl = 59140; First = 59140; Last = 60139 }
        @{ Band = 53; FdlLowMHz = 2483.5; NOffsDl = 60140; First = 60140; Last = 60254 }
        @{ Band = 54; FdlLowMHz = 1670; NOffsDl = 60255; First = 60255; Last = 60304 }
        @{ Band = 65; FdlLowMHz = 2110; NOffsDl = 65536; First = 65536; Last = 66435 }
        @{ Band = 66; FdlLowMHz = 2110; NOffsDl = 66436; First = 66436; Last = 67335 }
        @{ Band = 67; FdlLowMHz = 738; NOffsDl = 67336; First = 67336; Last = 67535 }
        @{ Band = 68; FdlLowMHz = 753; NOffsDl = 67536; First = 67536; Last = 67835 }
        @{ Band = 69; FdlLowMHz = 2570; NOffsDl = 67836; First = 67836; Last = 68335 }
        @{ Band = 70; FdlLowMHz = 1995; NOffsDl = 68336; First = 68336; Last = 68585 }
        @{ Band = 71; FdlLowMHz = 617; NOffsDl = 68586; First = 68586; Last = 68935 }
        @{ Band = 72; FdlLowMHz = 461; NOffsDl = 68936; First = 68936; Last = 68985 }
        @{ Band = 73; FdlLowMHz = 460; NOffsDl = 68986; First = 68986; Last = 69035 }
        @{ Band = 74; FdlLowMHz = 1475; NOffsDl = 69036; First = 69036; Last = 69465 }
        @{ Band = 75; FdlLowMHz = 1432; NOffsDl = 69466; First = 69466; Last = 70315 }
        @{ Band = 76; FdlLowMHz = 1427; NOffsDl = 70316; First = 70316; Last = 70365 }
        @{ Band = 85; FdlLowMHz = 728; NOffsDl = 70366; First = 70366; Last = 70545 }
        @{ Band = 87; FdlLowMHz = 420; NOffsDl = 70546; First = 70546; Last = 70595 }
        @{ Band = 88; FdlLowMHz = 422; NOffsDl = 70596; First = 70596; Last = 70645 }
        @{ Band = 103; FdlLowMHz = 757; NOffsDl = 70646; First = 70646; Last = 70655 }
        @{ Band = 106; FdlLowMHz = 935; NOffsDl = 70656; First = 70656; Last = 70705 }
        @{ Band = 111; FdlLowMHz = 1820; NOffsDl = 73386; First = 73386; Last = 73485 }
    )
}
