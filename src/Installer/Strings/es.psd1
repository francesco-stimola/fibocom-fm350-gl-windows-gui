# The texts of the installer and of the launcher in Spanish (Spain). Missing keys fall back to
# English (en.psd1). Placeholders {0}, {1}... are the same as in English; their order in a sentence
# may change. UTF-8 with a byte order mark: Windows PowerShell 5.1 reads it too.
@{
    # The launcher (Start-Fm350.ps1).
    'Launcher.Arm'       = 'Fibocom FM350-GL Windows GUI funciona en Windows de 64 bits con un procesador x64 (Intel o AMD). Este equipo tiene un procesador Arm, que no puede cargar el controlador del módem: no se ha instalado nada.'
    'Launcher.NotX64'    = 'Fibocom FM350-GL Windows GUI funciona en Windows de 64 bits con un procesador x64 (Intel o AMD), y este Windows no lo es: no se ha instalado nada.'
    'Launcher.NotFound'  = 'No se ha encontrado PowerShell 7.6 o posterior.'
    'Launcher.TooOld'    = 'El PowerShell 7 instalado es anterior a la versión 7.6.'
    'Launcher.Untrusted' = 'El PowerShell 7 encontrado no está en Program Files con una firma de Microsoft.'
    'Launcher.GetPwsh'   = '{0} Instálalo o actualízalo - winget install Microsoft.PowerShell, o desde Microsoft Store - y vuelve a intentarlo.'
    'Launcher.CantStart' = 'Fibocom FM350-GL Windows GUI no puede iniciarse. {0}'
    'Launcher.NoAdmin'   = 'Se necesitan permisos de administrador y no se han concedido: no se ha cambiado nada. ({0})'

    # The setup window (Invoke-Fm350Setup.ps1).
    'Setup.NeedsAdmin'   = 'Esto necesita permisos de administrador.'
    'Setup.OtherAccount' = 'Se respondió al aviso de UAC con otra cuenta: la aplicación se ejecuta con la cuenta que la instala, que debe ser de administrador. Inicia sesión con esa cuenta, o conviértela en administrador, y vuelve a ejecutar el .cmd. No se ha cambiado nada.'
    'Setup.Installing'   = 'Instalando Fibocom FM350-GL Windows GUI desde {0}'
    'Setup.Uninstalling' = 'Desinstalando Fibocom FM350-GL Windows GUI'
    'Setup.AskUserData'  = '¿Eliminar también la configuración, el PIN de la SIM y la contraseña del APN guardados, y los registros? [s/N]'
    # The answers that mean yes, as a regular expression; y and yes always do.
    'Setup.Yes'          = 's|si|sí'
    'Setup.Done'         = 'Listo.'
    'Setup.Failed'       = 'Error: {0}'
    'Setup.PressEnter'   = 'Presiona Entrar para cerrar esta ventana'

    # Installing and uninstalling (Installer.ps1).
    'Install.FolderExists'  = 'Ya existe la carpeta en la que copiar la aplicación: {0}'
    'Install.NotPackage'    = 'No es un paquete de la aplicación: {0}'
    'Install.StillRunning'  = 'La aplicación se está ejecutando y no se cerró en {0} s - ¿en otra sesión de Windows? Ciérrala allí (menú de la bandeja, Salir) y vuelve a ejecutar {1}. No se ha cambiado nada.'
    'Install.Exited'        = 'La aplicación en ejecución se ha cerrado; la conexión se queda como está.'
    'Install.Leftover'      = 'Restos de una instalación anterior, eliminados: {0}'
    'Install.NotAdminOnly'  = 'No solo los administradores podían modificar la copia: {0}'
    'Install.Copied'        = 'Copiados: {0} archivos.'
    'Install.Installed'     = 'Instalado en {0}.'
    'Install.InstalledOver' = 'Instalado en {0}, sobre la versión anterior.'
    'Install.OldFolder'     = 'Aún no se ha podido eliminar la carpeta de la versión anterior ({0}); la próxima instalación lo volverá a intentar.'
    'Install.Task'          = 'Tarea programada registrada: {0}.'
    'Install.TaskOff'       = 'Tarea programada registrada, desactivada: {0}. Se activa en la pestaña Conexión de la aplicación.'
    'Install.Shortcut'      = 'Acceso directo en el menú Inicio: {0}.'
    'Install.Entry'         = 'Añadida en Configuración > Aplicaciones > Aplicaciones instaladas, desde donde también se puede desinstalar.'
    'Install.Starting'      = 'La aplicación se está iniciando.'
    'Install.Restarted'     = 'La instalación se detuvo; la aplicación que se estaba ejecutando se inicia de nuevo desde la carpeta instalada.'
    'Install.NotRestarted'  = 'La instalación se detuvo y la aplicación que se estaba ejecutando no se pudo iniciar de nuevo ({0}): iníciala desde el menú Inicio.'
    'Install.NoIcon'        = 'No se ha podido dibujar el icono del acceso directo: {0}'
    'Install.NoIdentity'    = 'No se ha podido establecer la identidad del acceso directo en la barra de tareas: {0}'
    'Install.ShortcutTip'   = 'Mantiene en línea el Fibocom FM350-GL.'
    'Uninstall.Task'        = 'Tarea programada eliminada: {0}.'
    'Uninstall.Shortcut'    = 'Acceso directo del menú Inicio eliminado.'
    'Uninstall.Folder'      = 'Carpeta eliminada: {0}.'
    'Uninstall.Entry'       = 'Quitada de Configuración > Aplicaciones > Aplicaciones instaladas.'
    'Uninstall.UserData'    = 'Configuración, secretos y registros eliminados: {0}.'
}
