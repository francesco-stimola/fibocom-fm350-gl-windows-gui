# lpac, bundled in the release zip (docs/ARCHITECTURE.md -> eSIM): its official GitHub release,
# pinned. tools/New-ReleasePackage.ps1 takes each file from a cache or downloads it, and uses it
# only once its SHA-256 matches (docs/AT-COMMANDS.md section 8). The binaries are never committed.
#
# v2.2.1, not v2.3.0, whose stdio APDU backend doesn't work (decided 2026-10-04). GitHub lists no
# digest for v2.2.1's assets: the SHA-256 below is the one computed at the first download, from
# GitHub over HTTPS (decided 2026-10-04).
@{
    Version = '2.2.1'
    Page    = 'https://github.com/estkme-group/lpac/releases/tag/v2.2.1'

    # The Windows x64 build.
    Build   = @{
        Name   = 'lpac-windows-x86_64-mingw.zip'
        Url    = 'https://github.com/estkme-group/lpac/releases/download/v2.2.1/lpac-windows-x86_64-mingw.zip'
        Sha256 = 'be01d65219cd41f5d62cac60f3795366cf409b2f85fdbb545466e048246d3203'
    }

    # The build's files that go in the zip's 'lpac' folder: lpac.exe alone runs with the stdio
    # backends, and the app makes the HTTPS requests itself - libcurl.dll and its license stay out.
    Files   = @('lpac.exe', 'LICENSE-lpac', 'LICENSE-libeuicc', 'LICENSE-cjson', 'LICENSE-dlfcn-win32', 'README.md')

    # The corresponding source (AGPL-3.0), attached to the GitHub Release beside the zip: GitHub's
    # archive of the tag, the release having none of its own.
    Source  = @{
        Name   = 'lpac-2.2.1-source.tar.gz'
        Url    = 'https://github.com/estkme-group/lpac/archive/refs/tags/v2.2.1.tar.gz'
        Sha256 = '3d87080a625b10430eebb82f89e2d24e16a84a8435a9c40b3718fd88c82028ba'
    }
}
