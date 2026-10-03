# The texts of the installer and of the launcher in German: the same keys as English (en.psd1),
# which fills in any key missing here. Placeholders {0}, {1}... are filled in that order; a
# translation keeps the same ones. UTF-8 with a byte order mark: Windows PowerShell 5.1 reads it too.
@{
    # The launcher (Start-Fm350.ps1).
    'Launcher.Arm'       = 'Fibocom FM350-GL Windows GUI läuft unter 64-Bit-Windows auf einem x64-Prozessor (Intel oder AMD). Dieser Computer hat einen Arm-Prozessor, der den Treiber des Modems nicht laden kann: Es wurde nichts installiert.'
    'Launcher.NotX64'    = 'Fibocom FM350-GL Windows GUI läuft unter 64-Bit-Windows auf einem x64-Prozessor (Intel oder AMD), und dieses Windows ist kein solches: Es wurde nichts installiert.'
    'Launcher.NotFound'  = 'PowerShell 7.6 oder höher wurde nicht gefunden.'
    'Launcher.TooOld'    = 'Das installierte PowerShell 7 ist älter als 7.6.'
    'Launcher.Untrusted' = 'Das gefundene PowerShell 7 liegt nicht unter Program Files oder trägt keine Signatur von Microsoft.'
    'Launcher.GetPwsh'   = '{0} Installieren oder aktualisieren Sie es - winget install Microsoft.PowerShell oder über den Microsoft Store - und versuchen Sie es erneut.'
    'Launcher.CantStart' = 'Fibocom FM350-GL Windows GUI kann nicht gestartet werden. {0}'
    'Launcher.NoAdmin'   = 'Administratorrechte sind erforderlich und wurden nicht erteilt: Es wurde nichts geändert. ({0})'

    # The setup window (Invoke-Fm350Setup.ps1).
    'Setup.NeedsAdmin'   = 'Dafür sind Administratorrechte erforderlich.'
    'Setup.OtherAccount' = 'Die UAC-Abfrage wurde mit einem anderen Konto beantwortet: Die App läuft unter dem Konto, das sie installiert, und dieses muss ein Administrator sein. Melden Sie sich mit diesem Konto an oder machen Sie es zum Administrator, und führen Sie die .cmd-Datei erneut aus. Es wurde nichts geändert.'
    'Setup.Installing'   = 'Fibocom FM350-GL Windows GUI wird aus {0} installiert'
    'Setup.Uninstalling' = 'Fibocom FM350-GL Windows GUI wird deinstalliert'
    'Setup.AskUserData'  = 'Auch die Einstellungen, die gespeicherte SIM-PIN, das APN-Kennwort und die Protokolle löschen? [j/N]'
    # The answers that mean yes, as a regular expression; y and yes always do.
    'Setup.Yes'          = 'j|ja'
    'Setup.Done'         = 'Fertig.'
    'Setup.Failed'       = 'Fehlgeschlagen: {0}'
    'Setup.PressEnter'   = 'Drücken Sie die Eingabetaste, um dieses Fenster zu schließen'

    # Installing and uninstalling (Installer.ps1).
    'Install.FolderExists'  = 'Der Ordner, in den die App kopiert werden soll, ist bereits vorhanden: {0}'
    'Install.NotPackage'    = 'Kein Paket der App: {0}'
    'Install.StillRunning'  = 'Die App läuft und wurde nicht innerhalb von {0} s beendet - in einer anderen Windows-Sitzung? Beenden Sie sie dort (Menü im Infobereich, „Beenden“) und führen Sie {1} erneut aus. Es wurde nichts geändert.'
    'Install.Exited'        = 'Die laufende App wurde beendet; die Verbindung bleibt, wie sie ist.'
    'Install.Leftover'      = 'Rest einer früheren Installation gelöscht: {0}'
    'Install.NotAdminOnly'  = 'Nicht nur Administratoren konnten die Kopie ändern: {0}'
    'Install.Copied'        = 'Kopiert: {0} Dateien.'
    'Install.Installed'     = 'Installiert in {0}.'
    'Install.InstalledOver' = 'Installiert in {0}, über die frühere Version.'
    'Install.OldFolder'     = 'Der Ordner der früheren Version konnte noch nicht gelöscht werden ({0}); die nächste Installation versucht es erneut.'
    'Install.Task'          = 'Geplante Aufgabe registriert: {0}.'
    'Install.TaskOff'       = 'Geplante Aufgabe registriert, deaktiviert: {0}. Auf der Registerkarte Verbindung der App lässt sie sich aktivieren.'
    'Install.Shortcut'      = 'Verknüpfung im Startmenü: {0}.'
    'Install.Entry'         = 'In Einstellungen > Apps > Installierte Apps eingetragen, wo sie auch deinstalliert werden kann.'
    'Install.Starting'      = 'Die App wird gestartet.'
    'Install.Restarted'     = 'Die Installation wurde abgebrochen; die App, die lief, wird aus dem installierten Ordner wieder gestartet.'
    'Install.NotRestarted'  = 'Die Installation wurde abgebrochen, und die App, die lief, konnte nicht wieder gestartet werden ({0}): Starten Sie sie über das Startmenü.'
    'Install.NoIcon'        = 'Das Symbol der Verknüpfung konnte nicht gezeichnet werden: {0}'
    'Install.NoIdentity'    = 'Die Taskleisten-Identität der Verknüpfung konnte nicht festgelegt werden: {0}'
    'Install.ShortcutTip'   = 'Hält das Fibocom FM350-GL online.'
    'Uninstall.Task'        = 'Geplante Aufgabe entfernt: {0}.'
    'Uninstall.Shortcut'    = 'Verknüpfung im Startmenü entfernt.'
    'Uninstall.Folder'      = 'Ordner entfernt: {0}.'
    'Uninstall.Entry'       = 'Aus Einstellungen > Apps > Installierte Apps entfernt.'
    'Uninstall.UserData'    = 'Einstellungen, vertrauliche Daten und Protokolle entfernt: {0}.'
}
