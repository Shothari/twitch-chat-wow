@echo off
rem Ouvre le chat manuellement (normalement inutile : il se lance avec le jeu)
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0TwitchChatOverlay.ps1"
