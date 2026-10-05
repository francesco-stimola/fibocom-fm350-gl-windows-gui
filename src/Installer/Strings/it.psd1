# The texts of the installer and of the launcher in Italian: the same keys as en.psd1, which is the
# fallback of any key missing here. Placeholders {0}, {1}... are filled in that order; a translation
# keeps the same ones. UTF-8 with a byte order mark: Windows PowerShell 5.1 reads it too.
@{
    # The launcher (Start-Fm350.ps1).
    'Launcher.Not64'     = 'Fibocom FM350-GL Windows GUI funziona su Windows a 64 bit, con un processore x64 (Intel o AMD) o Arm64, e questa installazione di Windows non lo è: non è stato installato nulla.'
    'Launcher.NotFound'  = 'Non è stato trovato PowerShell 7.6 o versione successiva.'
    'Launcher.TooOld'    = 'La versione di PowerShell 7 installata è precedente alla 7.6.'
    'Launcher.Untrusted' = 'Il PowerShell 7 trovato non si trova in Program Files con una firma di Microsoft.'
    'Launcher.GetPwsh'   = '{0} Installalo o aggiornalo - winget install Microsoft.PowerShell, oppure dal Microsoft Store - e riprova.'
    'Launcher.CantStart' = 'Impossibile avviare Fibocom FM350-GL Windows GUI. {0}'
    'Launcher.NoAdmin'   = 'Servono i diritti di amministratore e non sono stati concessi: non è stato modificato nulla. ({0})'

    # The setup window (Invoke-Fm350Setup.ps1).
    'Setup.NeedsAdmin'   = 'Questa operazione richiede i diritti di amministratore.'
    'Setup.OtherAccount' = 'Alla richiesta UAC è stato risposto con un altro account: l''app viene eseguita con l''account che la installa, che deve essere un amministratore. Accedi con quell''account, oppure rendilo amministratore, ed esegui di nuovo il file .cmd. Non è stato modificato nulla.'
    'Setup.Installing'   = 'Installazione di Fibocom FM350-GL Windows GUI da {0}'
    'Setup.Uninstalling' = 'Disinstallazione di Fibocom FM350-GL Windows GUI'
    'Setup.AskUserData'  = 'Eliminare anche le impostazioni, il PIN della SIM e la password APN memorizzati, e i log? [s/N]'
    # The answers that mean yes, as a regular expression; y and yes always do.
    'Setup.Yes'          = 's|si|sì'
    'Setup.Done'         = 'Fatto.'
    'Setup.Failed'       = 'Operazione non riuscita: {0}'
    'Setup.PressEnter'   = 'Premi INVIO per chiudere questa finestra'

    # Installing and uninstalling (Installer.ps1).
    'Install.FolderExists'  = 'La cartella in cui copiare l''app esiste già: {0}'
    'Install.NotPackage'    = 'Non è un pacchetto dell''app: {0}'
    'Install.StillRunning'  = 'L''app è in esecuzione e non si è chiusa entro {0} s - in un''altra sessione di Windows? Chiudila lì (menu dell''area di notifica, Esci) ed esegui di nuovo {1}. Non è stato modificato nulla.'
    'Install.Exited'        = 'L''app in esecuzione si è chiusa; la connessione resta com''è.'
    'Install.Leftover'      = 'Residuo di un''installazione precedente, eliminato: {0}'
    'Install.NotAdminOnly'  = 'Non solo gli amministratori potevano modificare la copia: {0}'
    'Install.Copied'        = 'Copiati: {0} file.'
    'Install.Installed'     = 'Installato in {0}.'
    'Install.InstalledOver' = 'Installato in {0}, sopra la versione precedente.'
    'Install.OldFolder'     = 'Non è stato ancora possibile eliminare la cartella della versione precedente ({0}); la prossima installazione riprova.'
    'Install.Task'          = 'Attività pianificata registrata: {0}.'
    'Install.TaskOff'       = 'Attività pianificata registrata, disattivata: {0}. La attivi dalla scheda Connessione dell''app.'
    'Install.Shortcut'      = 'Collegamento nel menu Start: {0}.'
    'Install.Entry'         = 'Aggiunta in Impostazioni > App > App installate, da dove si può anche disinstallare.'
    'Install.Starting'      = 'Avvio dell''app in corso.'
    'Install.Restarted'     = 'L''installazione si è interrotta; l''app che era in esecuzione viene riavviata dalla cartella installata.'
    'Install.NotRestarted'  = 'L''installazione si è interrotta e non è stato possibile riavviare l''app che era in esecuzione ({0}): avviala dal menu Start.'
    'Install.NoIcon'        = 'Impossibile disegnare l''icona del collegamento: {0}'
    'Install.NoIdentity'    = 'Impossibile impostare l''identità del collegamento nella barra delle applicazioni: {0}'
    'Install.ShortcutTip'   = 'Mantiene online il Fibocom FM350-GL.'
    'Uninstall.Task'        = 'Attività pianificata rimossa: {0}.'
    'Uninstall.Shortcut'    = 'Collegamento nel menu Start rimosso.'
    'Uninstall.Folder'      = 'Cartella rimossa: {0}.'
    'Uninstall.Entry'       = 'Tolta da Impostazioni > App > App installate.'
    'Uninstall.UserData'    = 'Impostazioni, credenziali e log rimossi: {0}.'
    'Uninstall.UsbRestored' = 'Funzioni del modem tornate al driver che Windows giudica migliore - il driver seriale di MediaTek, dove è installato: {0}.'
    'Uninstall.UsbRestart'  = 'Funzioni del modem che tornano a quel driver al prossimo riavvio di Windows: {0}.'
    'Uninstall.UsbLeft'     = 'Funzioni del modem rimaste su WinUSB - le usa un altro programma, o Windows ha rifiutato; Gestione dispositivi può dar loro un altro driver: {0}.'
    'Uninstall.UsbAbsent'   = 'Funzioni di un modem non collegato, rimaste su WinUSB; una volta collegato, Gestione dispositivi può dar loro un altro driver: {0}.'
    'Uninstall.UsbFailed'   = 'Le funzioni del modem non si possono rimettere sul loro driver ({0}): restano su WinUSB.'
}
