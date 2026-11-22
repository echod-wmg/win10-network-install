@echo off
rem Runs Start-PxeInstall.ps1 as administrator.
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"%~dp0Start-PxeInstall.ps1\"'"
