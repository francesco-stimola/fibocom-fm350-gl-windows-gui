# lpac, bundled in the release zip (docs/ARCHITECTURE.md -> eSIM): its official GitHub release,
# pinned. tools/New-ReleasePackage.ps1 takes each file from a cache or downloads it, and uses it
# only once its SHA-256 matches (docs/AT-COMMANDS.md section 8, the digests GitHub lists). The
# binaries are never committed.
@{
    Version = '2.3.0'
    Page    = 'https://github.com/estkme-group/lpac/releases/tag/v2.3.0'

    # The Windows x64 build: lpac.exe, libcurl.dll, README.md and the licenses, put in the zip's
    # 'lpac' folder as they are.
    Build   = @{
        Name   = 'lpac-windows-x86_64-mingw.zip'
        Url    = 'https://github.com/estkme-group/lpac/releases/download/v2.3.0/lpac-windows-x86_64-mingw.zip'
        Sha256 = '4781e8673d19c08c41cd104e8bc59f901e352eb10e8c952bcf2aa199a915ea6f'
    }

    # The corresponding source (AGPL-3.0), attached to the GitHub Release beside the zip: GitHub's
    # archive of the tag, the release having none of its own.
    Source  = @{
        Name   = 'lpac-2.3.0-source.tar.gz'
        Url    = 'https://github.com/estkme-group/lpac/archive/refs/tags/v2.3.0.tar.gz'
        Sha256 = '661dffbd1e9e5732dab4a0bb0a9837d4906c8c66bd748bda262fe3e8d3e420f6'
    }
}
