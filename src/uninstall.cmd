@echo off
rem Uninstalls fibocom-fm350-gl-windows-gui: its logon tasks, its Start-menu shortcut and its folder
rem under Program Files. One UAC prompt. The connection is left as it is, as Exit leaves it.
rem It may run from the folder it deletes: the current folder moves away from it first, and the
rem last line is read whole before it runs.
cd /d "%SystemRoot%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Start-Fm350.ps1" -Mode Uninstall & if errorlevel 1 (pause & exit /b 1) else (exit /b 0)
