@echo off
rem Uninstalls fibocom-fm350-gl-windows-gui: its logon tasks, its Start-menu shortcut and its folder
rem under Program Files. One UAC prompt. The connection is left as it is, as Exit leaves it.
rem It may run from the folder it deletes: the current folder moves away from it first, the last
rem line is read whole before it runs, and (goto) leaves this file before the exit - cmd would
rem otherwise look for it once its folder is gone, and exit 1.
cd /d "%SystemRoot%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Start-Fm350.ps1" -Mode Uninstall & (goto) 2>nul & if errorlevel 1 (pause & exit /b 1) else (exit /b 0)
