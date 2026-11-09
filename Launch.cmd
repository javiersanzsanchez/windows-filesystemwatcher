@echo off
rem Usage:
rem   Launch.cmd            -> opens the menu (add a program, run one, restore)
rem   Launch.cmd <alias>    -> watches and launches that alias (must exist in config.json)
if "%~1"=="" (
  start "" /b powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Launcher.ps1" -ConfigPath "%~dp0config.json"
) else (
  start "" /b powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Watch-Backup.ps1" -Alias "%~1" -ConfigPath "%~dp0config.json"
)