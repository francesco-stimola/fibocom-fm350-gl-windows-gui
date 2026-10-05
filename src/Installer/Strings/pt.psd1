# The texts of the installer and of the launcher in Portuguese (European, also read by Brazilian
# users): the same keys as en.psd1. Placeholders {0}, {1}... are filled in that order; a translation
# keeps the same ones. UTF-8 with a byte order mark: Windows PowerShell 5.1 reads it too.
@{
    # The launcher (Start-Fm350.ps1).
    'Launcher.Not64'     = 'O Fibocom FM350-GL Windows GUI funciona em Windows de 64 bits num processador x64 (Intel ou AMD) ou Arm64, e este Windows não é desse tipo: nada foi instalado.'
    'Launcher.NotFound'  = 'Não foi encontrado o PowerShell 7.6 ou posterior.'
    'Launcher.TooOld'    = 'O PowerShell 7 instalado é anterior à versão 7.6.'
    'Launcher.Untrusted' = 'O PowerShell 7 encontrado não está em Program Files com uma assinatura da Microsoft.'
    'Launcher.GetPwsh'   = '{0} Instale-o ou atualize-o - winget install Microsoft.PowerShell, ou a partir da Microsoft Store - e tente novamente.'
    'Launcher.CantStart' = 'O Fibocom FM350-GL Windows GUI não consegue iniciar. {0}'
    'Launcher.NoAdmin'   = 'São necessários direitos de administrador, e não foram concedidos: nada foi alterado. ({0})'

    # The setup window (Invoke-Fm350Setup.ps1).
    'Setup.NeedsAdmin'   = 'Isto requer direitos de administrador.'
    'Setup.OtherAccount' = 'O pedido do UAC foi respondido com outra conta: a aplicação é executada com a conta que a instala, que tem de ser administrador. Inicie sessão com essa conta, ou torne-a administrador, e execute novamente o .cmd. Nada foi alterado.'
    'Setup.Installing'   = 'A instalar o Fibocom FM350-GL Windows GUI a partir de {0}'
    'Setup.Uninstalling' = 'A desinstalar o Fibocom FM350-GL Windows GUI'
    'Setup.AskUserData'  = 'Eliminar também as definições, o PIN do SIM e a palavra-passe do APN guardados, e os registos? [s/N]'
    # The answers that mean yes, as a regular expression; y and yes always do.
    'Setup.Yes'          = 's|sim'
    'Setup.Done'         = 'Concluído.'
    'Setup.Failed'       = 'Falhou: {0}'
    'Setup.PressEnter'   = 'Prima Enter para fechar esta janela'

    # Installing and uninstalling (Installer.ps1).
    'Install.FolderExists'  = 'A pasta para onde copiar a aplicação já existe: {0}'
    'Install.NotPackage'    = 'Não é um pacote da aplicação: {0}'
    'Install.StillRunning'  = 'A aplicação está em execução e não terminou em {0} s - noutra sessão do Windows? Feche-a lá (menu da área de notificação, Sair) e execute {1} novamente. Nada foi alterado.'
    'Install.Exited'        = 'A aplicação em execução terminou; a ligação mantém-se como está.'
    'Install.Leftover'      = 'Item deixado por uma instalação anterior, eliminado: {0}'
    'Install.NotAdminOnly'  = 'A cópia podia ser alterada não só por administradores: {0}'
    'Install.Copied'        = 'Copiados: {0} ficheiros.'
    'Install.Installed'     = 'Instalado em {0}.'
    'Install.InstalledOver' = 'Instalado em {0}, sobre a versão anterior.'
    'Install.OldFolder'     = 'Ainda não foi possível eliminar a pasta da versão anterior ({0}); a próxima instalação tenta novamente.'
    'Install.Task'          = 'Tarefa agendada registada: {0}.'
    'Install.TaskOff'       = 'Tarefa agendada registada, desativada: {0}. Ativa-se no separador Ligação da aplicação.'
    'Install.Shortcut'      = 'Atalho no menu Iniciar: {0}.'
    'Install.Entry'         = 'Adicionada em Definições > Aplicações > Aplicações instaladas, de onde também pode ser desinstalada.'
    'Install.Starting'      = 'A aplicação está a iniciar.'
    'Install.Restarted'     = 'A instalação parou; a aplicação que estava em execução é iniciada de novo a partir da pasta instalada.'
    'Install.NotRestarted'  = 'A instalação parou e não foi possível iniciar de novo a aplicação que estava em execução ({0}): inicie-a a partir do menu Iniciar.'
    'Install.NoIcon'        = 'Não foi possível desenhar o ícone do atalho: {0}'
    'Install.NoIdentity'    = 'Não foi possível definir a identidade do atalho na barra de tarefas: {0}'
    'Install.ShortcutTip'   = 'Mantém o Fibocom FM350-GL online.'
    'Uninstall.Task'        = 'Tarefa agendada removida: {0}.'
    'Uninstall.Shortcut'    = 'Atalho no menu Iniciar removido.'
    'Uninstall.Folder'      = 'Pasta removida: {0}.'
    'Uninstall.Entry'       = 'Removida de Definições > Aplicações > Aplicações instaladas.'
    'Uninstall.UserData'    = 'Definições, segredos e registos removidos: {0}.'
    'Uninstall.UsbRestored' = 'Funções do modem devolvidas ao controlador que o Windows considera melhor - o controlador série da MediaTek, onde está instalado: {0}.'
    'Uninstall.UsbRestart'  = 'Funções do modem que voltam a esse controlador no próximo reinício do Windows: {0}.'
    'Uninstall.UsbLeft'     = 'Funções do modem que ficam no WinUSB - outro programa usa-as, ou o Windows recusou; o Gestor de Dispositivos pode dar-lhes outro controlador: {0}.'
    'Uninstall.UsbNoModem'  = 'Nenhum modem ligado: as funções que a aplicação passou para o WinUSB ficam nele; o Gestor de Dispositivos pode dar-lhes outro controlador.'
    'Uninstall.UsbFailed'   = 'Não é possível devolver as funções do modem ao seu controlador ({0}): ficam no WinUSB.'
}
