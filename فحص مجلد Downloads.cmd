@echo off
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0BigFileFinder.ps1" -Path "%USERPROFILE%\Downloads" -MinSizeMB 50 -AutoScan
