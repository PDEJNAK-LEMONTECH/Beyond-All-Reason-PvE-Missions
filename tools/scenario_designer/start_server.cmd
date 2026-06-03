@echo off
REM ===================================================================
REM  One-click launcher for the BAR Scenario Designer server.
REM
REM  Double-click this file to start serve.ps1. It passes
REM  -ExecutionPolicy Bypass so it works even when the machine's
REM  PowerShell policy is "Restricted" (the Windows default) -- which
REM  otherwise makes a double-clicked serve.ps1 die instantly with no
REM  tray icon. Any arguments you add are forwarded (e.g. -DryRun, -Port 9000).
REM
REM  The window stays open after the server stops (or errors) so you can
REM  read any message instead of it flashing closed.
REM ===================================================================
title BAR Scenario Designer server
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve.ps1" %*
echo.
echo === Server stopped. Press any key to close this window. ===
pause >nul
