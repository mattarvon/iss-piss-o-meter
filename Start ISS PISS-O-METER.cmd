@echo off
rem Launches the ISS PISS-O-METER tray app, hidden, via the trusted pwsh.exe.
start "" pwsh -NoProfile -WindowStyle Hidden -File "%~dp0IssPissOMeter.ps1"
