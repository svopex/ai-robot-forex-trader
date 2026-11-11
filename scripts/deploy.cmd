@echo off
REM Spusti nasazeni experta AiRobotForexTrader i na strojich, kde je zakazane
REM spousteni PowerShell skriptu (ExecutionPolicy Restricted).
REM Pouziti:  deploy.cmd  [-All | -Broker "IC Markets"]  [-NoCompile]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
