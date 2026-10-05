# The texts of the installer and of the launcher in Polish: every key of the English file, with the
# same placeholders. Placeholders {0}, {1}... are filled in that order; a translation keeps the same
# ones. UTF-8 with a byte order mark: Windows PowerShell 5.1 reads it too.
@{
    # The launcher (Start-Fm350.ps1).
    'Launcher.Not64'     = 'Fibocom FM350-GL Windows GUI działa w 64-bitowym systemie Windows na procesorze x64 (Intel lub AMD) lub Arm64, a ten system Windows takim nie jest: nic nie zostało zainstalowane.'
    'Launcher.NotFound'  = 'Nie znaleziono programu PowerShell 7.6 lub nowszego.'
    'Launcher.TooOld'    = 'Zainstalowany PowerShell 7 jest starszy niż 7.6.'
    'Launcher.Untrusted' = 'Znaleziony PowerShell 7 nie znajduje się w folderze Program Files z podpisem firmy Microsoft.'
    'Launcher.GetPwsh'   = '{0} Zainstaluj go lub zaktualizuj - winget install Microsoft.PowerShell lub ze sklepu Microsoft Store - i spróbuj ponownie.'
    'Launcher.CantStart' = 'Nie można uruchomić Fibocom FM350-GL Windows GUI. {0}'
    'Launcher.NoAdmin'   = 'Wymagane są uprawnienia administratora, a nie zostały przyznane: nic nie zostało zmienione. ({0})'

    # The setup window (Invoke-Fm350Setup.ps1).
    'Setup.NeedsAdmin'   = 'To wymaga uprawnień administratora.'
    'Setup.OtherAccount' = 'Na monit UAC odpowiedziano przy użyciu innego konta: aplikacja działa na koncie, które ją instaluje, a to konto musi być administratorem. Zaloguj się na to konto lub nadaj mu uprawnienia administratora i ponownie uruchom plik .cmd. Nic nie zostało zmienione.'
    'Setup.Installing'   = 'Instalowanie Fibocom FM350-GL Windows GUI z {0}'
    'Setup.Uninstalling' = 'Odinstalowywanie Fibocom FM350-GL Windows GUI'
    'Setup.AskUserData'  = 'Usunąć również ustawienia, zapisany kod PIN karty SIM, hasło APN i dzienniki? [t/N]'
    # The answers that mean yes, as a regular expression; y and yes always do.
    'Setup.Yes'          = 't|tak'
    'Setup.Done'         = 'Gotowe.'
    'Setup.Failed'       = 'Niepowodzenie: {0}'
    'Setup.PressEnter'   = 'Naciśnij Enter, aby zamknąć to okno'

    # Installing and uninstalling (Installer.ps1).
    'Install.FolderExists'  = 'Folder, do którego ma zostać skopiowana aplikacja, już istnieje: {0}'
    'Install.NotPackage'    = 'To nie jest pakiet aplikacji: {0}'
    'Install.StillRunning'  = 'Aplikacja działa i nie zakończyła pracy w ciągu {0} s - w innej sesji Windows? Zakończ ją tam (menu w zasobniku, Zakończ) i ponownie uruchom {1}. Nic nie zostało zmienione.'
    'Install.Exited'        = 'Uruchomiona aplikacja zakończyła pracę; połączenie pozostaje bez zmian.'
    'Install.Leftover'      = 'Usunięto pozostałość po wcześniejszej instalacji: {0}'
    'Install.NotAdminOnly'  = 'Kopię mogli zmienić nie tylko administratorzy: {0}'
    'Install.Copied'        = 'Skopiowane pliki: {0}.'
    'Install.Installed'     = 'Zainstalowano w {0}.'
    'Install.InstalledOver' = 'Zainstalowano w {0}, zastępując wcześniejszą wersję.'
    'Install.OldFolder'     = 'Nie udało się jeszcze usunąć folderu wcześniejszej wersji ({0}); następna instalacja spróbuje ponownie.'
    'Install.Task'          = 'Zarejestrowano zadanie zaplanowane: {0}.'
    'Install.TaskOff'       = 'Zarejestrowano zaplanowane zadanie, wyłączone: {0}. Można je włączyć na karcie Połączenie aplikacji.'
    'Install.Shortcut'      = 'Skrót w menu Start: {0}.'
    'Install.Entry'         = 'Dodano w Ustawienia > Aplikacje > Zainstalowane aplikacje, skąd można ją też odinstalować.'
    'Install.Starting'      = 'Aplikacja się uruchamia.'
    'Install.Restarted'     = 'Instalacja została przerwana; aplikacja, która była uruchomiona, zostaje uruchomiona ponownie z zainstalowanego folderu.'
    'Install.NotRestarted'  = 'Instalacja została przerwana, a aplikacji, która była uruchomiona, nie udało się uruchomić ponownie ({0}): uruchom ją z menu Start.'
    'Install.NoIcon'        = 'Nie udało się narysować ikony skrótu: {0}'
    'Install.NoIdentity'    = 'Nie udało się ustawić tożsamości skrótu na pasku zadań: {0}'
    'Install.ShortcutTip'   = 'Utrzymuje modem Fibocom FM350-GL w trybie online.'
    'Uninstall.Task'        = 'Usunięto zadanie zaplanowane: {0}.'
    'Uninstall.Shortcut'    = 'Usunięto skrót z menu Start.'
    'Uninstall.Folder'      = 'Usunięto folder: {0}.'
    'Uninstall.Entry'       = 'Usunięto z Ustawienia > Aplikacje > Zainstalowane aplikacje.'
    'Uninstall.UserData'    = 'Usunięto ustawienia, dane poufne i dzienniki: {0}.'
    'Uninstall.UsbRestored' = 'Funkcje modemu przywrócone do sterownika, który Windows uznaje za najlepszy - sterownika szeregowego MediaTek, tam gdzie jest zainstalowany: {0}.'
    'Uninstall.UsbRestart'  = 'Funkcje modemu, które wrócą do tego sterownika po następnym ponownym uruchomieniu systemu Windows: {0}.'
    'Uninstall.UsbLeft'     = 'Funkcje modemu pozostawione bez zmian - używa ich inny program, Windows odmówił albo nie udało się ich odczytać; Menedżer urządzeń może przypisać im inny sterownik: {0}.'
    'Uninstall.UsbRemoved'  = 'Funkcje niepodłączonego modemu, usunięte z systemu Windows - wybierze on ich sterownik od nowa po podłączeniu modemu: {0}.'
    'Uninstall.UsbAbsent'   = 'Funkcje niepodłączonego modemu pozostawione na WinUSB; po jego podłączeniu Menedżer urządzeń może przypisać im inny sterownik: {0}.'
    'Uninstall.UsbFailed'   = 'Nie można przywrócić funkcji modemu do ich sterownika ({0}): pozostają na WinUSB.'
}
