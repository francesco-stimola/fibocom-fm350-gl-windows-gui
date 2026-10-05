# The texts of the installer and of the launcher in English: every key, and the fallback of every
# other language. Placeholders {0}, {1}... are filled in that order; a translation keeps the same
# ones. UTF-8 with a byte order mark: Windows PowerShell 5.1 reads it too.
@{
    # The launcher (Start-Fm350.ps1).
    'Launcher.Not64'     = 'Fibocom FM350-GL Windows GUI runs on 64-bit Windows, on an x64 (Intel or AMD) or an Arm64 processor, and this Windows is not one: nothing was installed.'
    'Launcher.NotFound'  = 'PowerShell 7.6 or later was not found.'
    'Launcher.TooOld'    = 'The PowerShell 7 installed is older than 7.6.'
    'Launcher.Untrusted' = 'The PowerShell 7 found is not under Program Files with a signature of Microsoft.'
    'Launcher.GetPwsh'   = '{0} Install or update it - winget install Microsoft.PowerShell, or from the Microsoft Store - and try again.'
    'Launcher.CantStart' = 'Fibocom FM350-GL Windows GUI can''t start. {0}'
    'Launcher.NoAdmin'   = 'Administrator rights are needed, and were not given: nothing was changed. ({0})'

    # The setup window (Invoke-Fm350Setup.ps1).
    'Setup.NeedsAdmin'   = 'This needs administrator rights.'
    'Setup.OtherAccount' = 'The UAC prompt was answered with another account: the app runs as the account that installs it, which must be an administrator. Sign in with that account, or make it an administrator, and run the .cmd again. Nothing was changed.'
    'Setup.Installing'   = 'Installing Fibocom FM350-GL Windows GUI from {0}'
    'Setup.Uninstalling' = 'Uninstalling Fibocom FM350-GL Windows GUI'
    'Setup.AskUserData'  = 'Also delete the settings, the stored SIM PIN and APN password, and the logs? [y/N]'
    # The answers that mean yes, as a regular expression; y and yes always do.
    'Setup.Yes'          = 'y|yes'
    'Setup.Done'         = 'Done.'
    'Setup.Failed'       = 'Failed: {0}'
    'Setup.PressEnter'   = 'Press Enter to close this window'

    # Installing and uninstalling (Installer.ps1).
    'Install.FolderExists'  = 'The folder to copy the app into exists already: {0}'
    'Install.NotPackage'    = 'Not a package of the app: {0}'
    'Install.StillRunning'  = 'The app is running and didn''t exit within {0} s - in another Windows session? Exit it there (tray menu, Exit) and run {1} again. Nothing was changed.'
    'Install.Exited'        = 'The running app exited; the connection stays as it is.'
    'Install.Leftover'      = 'Left over from an earlier installation, deleted: {0}'
    'Install.NotAdminOnly'  = 'Not only administrators could change the copy: {0}'
    'Install.Copied'        = 'Copied: {0} files.'
    'Install.Installed'     = 'Installed in {0}.'
    'Install.InstalledOver' = 'Installed in {0}, over the earlier version.'
    'Install.OldFolder'     = 'The earlier version''s folder couldn''t be deleted yet ({0}); the next installation tries again.'
    'Install.Task'          = 'Scheduled task registered: {0}.'
    'Install.TaskOff'       = 'Scheduled task registered, off: {0}. The app''s Connection tab turns it on.'
    'Install.Shortcut'      = 'Start-menu shortcut: {0}.'
    'Install.Entry'         = 'Listed in Settings > Apps > Installed apps, where it can be uninstalled too.'
    'Install.Starting'      = 'The app is starting.'
    'Install.Restarted'     = 'The installation stopped; the app that was running is started again, from the folder in place.'
    'Install.NotRestarted'  = 'The installation stopped, and the app that was running couldn''t be started again ({0}): start it from the Start menu.'
    'Install.NoIcon'        = 'The shortcut''s icon couldn''t be drawn: {0}'
    'Install.NoIdentity'    = 'The shortcut''s taskbar identity couldn''t be set: {0}'
    'Install.ShortcutTip'   = 'Keeps the Fibocom FM350-GL online.'
    'Uninstall.Task'        = 'Scheduled task removed: {0}.'
    'Uninstall.Shortcut'    = 'Start-menu shortcut removed.'
    'Uninstall.Folder'      = 'Folder removed: {0}.'
    'Uninstall.Entry'       = 'Taken off Settings > Apps > Installed apps.'
    'Uninstall.UserData'    = 'Settings, secrets and logs removed: {0}.'
    'Uninstall.UsbRestored' = 'The modem''s functions back on the driver Windows ranks best - MediaTek''s serial driver where it is installed: {0}.'
    'Uninstall.UsbRestart'  = 'The modem''s functions back on that driver at the next restart of Windows: {0}.'
    'Uninstall.UsbLeft'     = 'The modem''s functions left on WinUSB - another program uses them, or Windows refused; Device Manager can give them another driver: {0}.'
    'Uninstall.UsbRemoved'  = 'The functions of a modem not plugged in, removed from Windows - it chooses their driver afresh when the modem is plugged in: {0}.'
    'Uninstall.UsbAbsent'   = 'The functions of a modem not plugged in, left on WinUSB; once it is plugged in, Device Manager can give them another driver: {0}.'
    'Uninstall.UsbFailed'   = 'The modem''s functions can''t be given back to their driver ({0}): they stay on WinUSB.'
}
