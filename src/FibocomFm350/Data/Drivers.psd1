# The driver packages the app knows for the modem's AT ports (ARCHITECTURE -> Drivers): the SHA-256
# of their files and where a copy is published - hashes and links only. The project never
# distributes a driver: the user downloads it, and a package whose files all match one of these is
# reported as a verified version. Facts and sources: docs/AT-COMMANDS.md section 1.1.
@{
    Packages = @(
        @{
            Name    = 'MediaTek usb2ser_tm'
            Version = '3.22.43.1'
            # The files, by their path relative to the INF's folder.
            Files   = @{
                'usb2ser_tm.cat'     = '39b8eaa7bcc86e8b9ab19f00755852f04a31a79992b95ae06606dc6383352197'
                'usb2ser_tm.inf'     = '86254f45d729fd787650ede591412d64d61da1fbc80f7a03ec44a876e2401509'
                'x64/usb2ser_tm.sys' = '2292b04b4d0c0659257078e2480d0a49fb5672ce9c4ff8461ade1504ebecdeaa'
                'x86/usb2ser_tm.sys' = '7dbb1edd585c5e49a8e7db05a2100b165436e3bd9cceb4d82c7dcf473624e5ca'
            }
            # Where a copy is published: a third party's copy of MediaTek's driver, an archive of
            # the package's four files; the page is pinned to a commit.
            Copy    = @{
                Publisher = 'the GitHub repository prusa-dev/fibocom-connect-fm350'
                Page      = 'https://github.com/prusa-dev/fibocom-connect-fm350/blob/b15f3ad83b6e14d2f4c3658ac6ec382849a0e571/drivers/acer_v3.22.43.1.zip'
                File      = 'acer_v3.22.43.1.zip'
                Sha256    = 'ecdaa30469873bd44e834c1fd65c655269fb9a550f2e5d28f3e48031cab3c2b9'
            }
        }
    )
}
