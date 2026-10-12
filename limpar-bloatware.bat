@echo off
setlocal
title Limpar bloatware - IGN
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo  Sem privilegio de admin - pedindo elevacao ^(vai abrir o UAC^)...
  echo  Se pedir usuario e senha, este login nao e' administrador local.
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  timeout /t 3 >nul
  exit /b
)

echo  Rodando como ADMIN. Log em Desktop\UTI-backup.
echo.
if exist "%~dp0limpar-bloatware.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0limpar-bloatware.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/limpar-bloatware.ps1 | iex"
)

echo.
echo  ===== Se voce esta lendo isto, o script terminou. =====
echo  Log: Desktop\UTI-backup\limpar-bloatware-log_*.txt
pause
