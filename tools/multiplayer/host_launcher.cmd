@echo off
REM ===================================================================
REM  One-click launcher for the BAR PvE host GUI.
REM
REM  Double-click this file. It runs host_launcher.ps1 with
REM  -ExecutionPolicy Bypass so it works even when this machine's
REM  PowerShell policy is "Restricted" (the Windows default) -- which
REM  otherwise makes a double-clicked .ps1 die instantly.
REM
REM  The window stays open after the GUI closes so you can read any
REM  message instead of it flashing shut.
REM ===================================================================
title BAR PvE Host
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0host_launcher.ps1" %*
echo.
echo === Host launcher closed. Press any key to close this window. ===
pause >nul
