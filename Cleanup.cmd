@echo off
rem Runs Stop-PxeInstall.ps1 as administrator. Only needed if the server was killed without cleaning up.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"%~dp0Stop-PxeInstall.ps1\"'"
