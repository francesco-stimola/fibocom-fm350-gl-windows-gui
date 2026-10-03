@echo off
rem Installs fibocom-fm350-gl-windows-gui, or updates it: copies the app under Program Files,
rem registers its logon task and adds it to the Start menu. One UAC prompt. Running again over an
rem installed copy replaces it; a running app is asked to exit first and started again after.
rem Start-Fm350.ps1 finds PowerShell 7 (docs/ARCHITECTURE.md -> Installing and updating).
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Start-Fm350.ps1" -Mode Install
if errorlevel 1 pause
