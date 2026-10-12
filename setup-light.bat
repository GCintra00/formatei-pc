@echo off
setlocal
title Setup light - IGN
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

echo  Rodando como ADMIN. Log em Downloads.
echo.
if exist "%~dp0setup-light.ps1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-light.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/setup-light.ps1 | iex"
)

echo.
echo  ===== Se voce esta lendo isto, o script terminou. =====
echo  Log: Downloads\formatei-light-log_*.txt
pause
