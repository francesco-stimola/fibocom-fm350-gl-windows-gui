# ZXing.Net, bundled in the release zip to read an eSIM activation code from the image of its QR
# code (docs/ARCHITECTURE.md -> eSIM; decided 2026-10-04): its package on nuget.org, pinned.
# tools/New-ReleasePackage.ps1 takes each file from a cache or downloads it, and uses it only once
# its SHA-256 matches. The binaries are never committed.
@{
    Version = '0.16.11'
    Page    = 'https://www.nuget.org/packages/ZXing.Net/0.16.11'

    # The package. nuget.org lists its SHA-512, which it matched when it was pinned:
    # kHBBMH1ZKN4Y5IZY8Cq6iETXOr7k00ZrJ8Nbsow9QlTcJZvJVR26bX7VMR/oY1XOJuPzLyMu79WKdw+bKhechg==
    Package = @{
        Name   = 'zxing.net.0.16.11.nupkg'
        Url    = 'https://api.nuget.org/v3-flatcontainer/zxing.net/0.16.11/zxing.net.0.16.11.nupkg'
        Sha256 = '7d39234d668e558b3d374d18116ed57021d7c0df482801f1e1db4f1db9314ec3'
    }

    # The package's files that go in the zip's 'zxing' folder, and their names there: the library
    # built for .NET 9, which PowerShell 7.6 loads.
    Files   = @{ 'lib/net9.0/zxing.dll' = 'zxing.dll' }

    # Its license, Apache-2.0, which the package doesn't carry: the project's own copy at the
    # release's tag.
    License = @{
        Name   = 'COPYING'
        Url    = 'https://raw.githubusercontent.com/micjahn/ZXing.Net/v0.16.11.0/COPYING'
        Sha256 = 'c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4'
    }
}
