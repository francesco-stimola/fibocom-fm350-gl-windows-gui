# The texts of the installer and of the launcher in French. Same keys as en.psd1, the fallback of
# any key missing here. Placeholders {0}, {1}... keep the meaning they have in English. UTF-8 with a
# byte order mark: Windows PowerShell 5.1 reads it too.
@{
    # The launcher (Start-Fm350.ps1).
    'Launcher.Not64'     = 'Fibocom FM350-GL Windows GUI fonctionne sous Windows 64 bits sur un processeur x64 (Intel ou AMD) ou Arm64, ce qui n''est pas le cas de ce Windows : rien n''a été installé.'
    'Launcher.NotFound'  = 'PowerShell 7.6 ou version ultérieure est introuvable.'
    'Launcher.TooOld'    = 'Le PowerShell 7 installé est antérieur à la version 7.6.'
    'Launcher.Untrusted' = 'Le PowerShell 7 détecté n''est pas sous Program Files avec une signature de Microsoft.'
    'Launcher.GetPwsh'   = '{0} Installez-le ou mettez-le à jour - winget install Microsoft.PowerShell, ou depuis le Microsoft Store - puis réessayez.'
    'Launcher.CantStart' = 'Fibocom FM350-GL Windows GUI ne peut pas démarrer. {0}'
    'Launcher.NoAdmin'   = 'Des droits d''administrateur sont nécessaires et n''ont pas été accordés : rien n''a été modifié. ({0})'

    # The setup window (Invoke-Fm350Setup.ps1).
    'Setup.NeedsAdmin'   = 'Cette opération nécessite des droits d''administrateur.'
    'Setup.OtherAccount' = 'L''invite UAC a été validée avec un autre compte : l''application s''exécute sous le compte qui l''installe, qui doit être administrateur. Connectez-vous avec ce compte, ou faites-en un administrateur, puis exécutez à nouveau le .cmd. Rien n''a été modifié.'
    'Setup.Installing'   = 'Installation de Fibocom FM350-GL Windows GUI depuis {0}'
    'Setup.Uninstalling' = 'Désinstallation de Fibocom FM350-GL Windows GUI'
    'Setup.AskUserData'  = 'Supprimer aussi les paramètres, le code PIN de la SIM et le mot de passe APN mémorisés, ainsi que les journaux ? [o/N]'
    # The answers that mean yes, as a regular expression; y and yes always do.
    'Setup.Yes'          = 'o|oui'
    'Setup.Done'         = 'Terminé.'
    'Setup.Failed'       = 'Échec : {0}'
    'Setup.PressEnter'   = 'Appuyez sur Entrée pour fermer cette fenêtre'

    # Installing and uninstalling (Installer.ps1).
    'Install.FolderExists'  = 'Le dossier où copier l''application existe déjà : {0}'
    'Install.NotPackage'    = 'Ce n''est pas un package de l''application : {0}'
    'Install.StillRunning'  = 'L''application est en cours d''exécution et ne s''est pas fermée en {0} s - dans une autre session Windows ? Quittez-la là-bas (menu de la zone de notification, Quitter) et exécutez à nouveau {1}. Rien n''a été modifié.'
    'Install.Exited'        = 'L''application en cours d''exécution s''est fermée ; la connexion reste telle quelle.'
    'Install.Leftover'      = 'Reste d''une installation précédente, supprimé : {0}'
    'Install.NotAdminOnly'  = 'La copie n''était pas modifiable par les seuls administrateurs : {0}'
    'Install.Copied'        = 'Fichiers copiés : {0}.'
    'Install.Installed'     = 'Installé dans {0}.'
    'Install.InstalledOver' = 'Installé dans {0}, par-dessus la version précédente.'
    'Install.OldFolder'     = 'Le dossier de la version précédente n''a pas encore pu être supprimé ({0}) ; la prochaine installation réessaiera.'
    'Install.Task'          = 'Tâche planifiée enregistrée : {0}.'
    'Install.TaskOff'       = 'Tâche planifiée enregistrée, désactivée : {0}. L''onglet Connexion de l''application l''active.'
    'Install.Shortcut'      = 'Raccourci du menu Démarrer : {0}.'
    'Install.Entry'         = 'Ajoutée dans Paramètres > Applications > Applications installées, d''où elle peut aussi être désinstallée.'
    'Install.Starting'      = 'L''application démarre.'
    'Install.Restarted'     = 'L''installation s''est arrêtée ; l''application qui tournait est redémarrée depuis le dossier installé.'
    'Install.NotRestarted'  = 'L''installation s''est arrêtée et l''application qui tournait n''a pas pu être redémarrée ({0}) : démarrez-la depuis le menu Démarrer.'
    'Install.NoIcon'        = 'L''icône du raccourci n''a pas pu être dessinée : {0}'
    'Install.NoIdentity'    = 'Impossible de définir l''identité du raccourci dans la barre des tâches : {0}'
    'Install.ShortcutTip'   = 'Maintient le Fibocom FM350-GL en ligne.'
    'Uninstall.Task'        = 'Tâche planifiée supprimée : {0}.'
    'Uninstall.Shortcut'    = 'Raccourci du menu Démarrer supprimé.'
    'Uninstall.Folder'      = 'Dossier supprimé : {0}.'
    'Uninstall.Entry'       = 'Retirée de Paramètres > Applications > Applications installées.'
    'Uninstall.UserData'    = 'Paramètres, secrets et journaux supprimés : {0}.'
    'Uninstall.UsbRestored' = 'Fonctions du modem rendues au pilote que Windows classe le mieux - le pilote série de MediaTek, là où il est installé : {0}.'
    'Uninstall.UsbRestart'  = 'Fonctions du modem rendues à ce pilote au prochain redémarrage de Windows : {0}.'
    'Uninstall.UsbLeft'     = 'Fonctions du modem laissées sur WinUSB - un autre programme les utilise, ou Windows a refusé ; le Gestionnaire de périphériques peut leur donner un autre pilote : {0}.'
    'Uninstall.UsbRemoved'  = 'Fonctions d''un modem non branché, retirées de Windows - il choisira de nouveau leur pilote quand le modem sera branché : {0}.'
    'Uninstall.UsbAbsent'   = 'Fonctions d''un modem non branché, laissées sur WinUSB ; une fois celui-ci branché, le Gestionnaire de périphériques peut leur donner un autre pilote : {0}.'
    'Uninstall.UsbFailed'   = 'Les fonctions du modem ne peuvent pas être rendues à leur pilote ({0}) : elles restent sur WinUSB.'
}
