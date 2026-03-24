# ============================================
# FORMATEI O PC E AGORA O QUE FAZER?
# Limpa bloatware, instala programas, configura
# Compativel com Windows 10 e 11
# ============================================

# Verificar se esta rodando como Administrador
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERRO: Execute este script como Administrador!" -ForegroundColor Red
    Write-Host "Clique com botao direito no PowerShell > Executar como Administrador" -ForegroundColor Yellow
    pause
    exit
}

# Corrigir DNS
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
    Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4") -ErrorAction SilentlyContinue
}
Write-Host "DNS configurado (Google 8.8.8.8)" -ForegroundColor Gray

$desktop = [Environment]::GetFolderPath("Desktop")
$etapaTotal = 5
$erros = @()
$instalados = @()
$ghRelease = "https://github.com/igcintra/formatei-pc/releases/download/v1.0"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  FORMATEI O PC E AGORA O QUE FAZER?" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ============================================
# [1] REMOVER BLOATWARE
# ============================================

Write-Host "`n[1/$etapaTotal] Removendo bloatware..." -ForegroundColor Cyan

$bloatware = @(
    "McAfee*",
    "Microsoft.OneDrive*",
    "Microsoft.MicrosoftTeams*",
    "MicrosoftTeams*",
    "MSTeams*",
    "Microsoft.Teams*",
    "Microsoft.Todos*",
    "Microsoft.MicrosoftSolitaireCollection*",
    "Microsoft.MicrosoftOfficeHub*",
    "Microsoft.BingNews*",
    "Microsoft.BingWeather*",
    "Microsoft.GetHelp*",
    "Microsoft.Getstarted*",
    "Microsoft.WindowsMail*",
    "Microsoft.windowscommunicationsapps*",
    "microsoft.windowscomm*",
    "Microsoft.SkypeApp*",
    "Microsoft.LinkedIn*",
    "Microsoft.Clipchamp*",
    "Microsoft.GamingApp*",
    "Microsoft.XboxApp*",
    "Microsoft.XboxGameOverlay*",
    "Microsoft.XboxGamingOverlay*",
    "Microsoft.XboxSpeechToTextOverlay*",
    "Microsoft.XboxIdentityProvider*",
    "Microsoft.Xbox.TCUI*",
    "SpotifyAB.SpotifyMusic*",
    "king.com.CandyCrushSaga*",
    "king.com.CandyCrush*",
    "BytedancePte.Ltd.TikTok*",
    "Facebook*",
    "Instagram*",
    "Disney*",
    "Clipchamp*"
)

$removidos = @()

foreach ($app in $bloatware) {
    $pacotes = Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue
    foreach ($pacote in $pacotes) {
        try {
            Remove-AppxPackage -Package $pacote.PackageFullName -AllUsers -ErrorAction Stop
            $removidos += $pacote.Name
            Write-Host "  Removido: $($pacote.Name)" -ForegroundColor Green
        } catch {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like $app } |
                ForEach-Object {
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
                    $removidos += $_.DisplayName
                }
        }
    }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $app } |
        ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
        }
}

# McAfee via WMI
$mcafee = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*McAfee*" }
foreach ($m in $mcafee) { $m.Uninstall() | Out-Null; $removidos += $m.Name }

# OneDrive
Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$onedrivePath = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $onedrivePath)) { $onedrivePath = "$env:SystemRoot\System32\OneDriveSetup.exe" }
if (Test-Path $onedrivePath) {
    Start-Process $onedrivePath -ArgumentList "/uninstall" -Wait -ErrorAction SilentlyContinue
    $removidos += "OneDrive"
}
winget uninstall --id Microsoft.OneDrive -e --silent 2>&1 | Out-Null

# Teams
Stop-Process -Name "ms-teams" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "Teams" -Force -ErrorAction SilentlyContinue
winget uninstall --id Microsoft.Teams -e --silent 2>&1 | Out-Null
winget uninstall --name "Microsoft Teams" --silent 2>&1 | Out-Null
$teamsPath = "$env:LOCALAPPDATA\Microsoft\Teams\Update.exe"
if (Test-Path $teamsPath) {
    Start-Process $teamsPath -ArgumentList "--uninstall -s" -Wait -ErrorAction SilentlyContinue
    $removidos += "Teams"
}

if ($removidos.Count -eq 0) {
    Write-Host "  Nenhum bloatware encontrado" -ForegroundColor Gray
} else {
    Write-Host "  $($removidos.Count) programa(s) removido(s)" -ForegroundColor Green
}

# ============================================
# [2] INSTALAR PROGRAMAS (via Winget)
# ============================================

Write-Host "`n[2/$etapaTotal] Instalando programas..." -ForegroundColor Cyan

$programas = @(
    @{ nome = "Google Chrome";       id = "Google.Chrome" },
    @{ nome = "Discord";             id = "Discord.Discord" },
    @{ nome = "Steam";               id = "Valve.Steam" },
    @{ nome = "Epic Games";          id = "EpicGames.EpicGamesLauncher" },
    @{ nome = "Opera GX";            id = "Opera.OperaGX" },
    @{ nome = "Bambu Studio";        id = "Bambulab.Bambustudio" },
    @{ nome = "Fusion 360";          id = "Autodesk.Fusion" },
    @{ nome = "Logitech G Hub";      id = "Logitech.GHUB" },
    @{ nome = "Lightshot";           id = "Skillbrains.Lightshot" },
    @{ nome = "WinRAR";              id = "RARLab.WinRAR" },
    @{ nome = "Calibre";             id = "calibre.calibre" },
    @{ nome = "HakuNeko";            id = "HakuNeko.HakuNeko" },
    @{ nome = "KCC";                 id = "ciromattia.KCC" },
    @{ nome = "Kindle Previewer";    id = "Amazon.KindlePreviewer" }
)

$total = $programas.Count + 1  # +1 para AnyDesk
$atual = 0

foreach ($prog in $programas) {
    $atual++
    Write-Host "  [$atual/$total] $($prog.nome)..." -ForegroundColor Yellow -NoNewline

    $resultado = winget install --id $prog.id -e --accept-source-agreements --accept-package-agreements --silent 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host " OK" -ForegroundColor Green
        $instalados += "$($prog.nome) - Instalado"
    } elseif ($resultado -match "already installed") {
        Write-Host " Ja instalado" -ForegroundColor Gray
        $instalados += "$($prog.nome) - Ja instalado"
    } else {
        Write-Host " ERRO" -ForegroundColor Red
        $instalados += "$($prog.nome) - ERRO"
        $erros += $prog.nome
    }
}

# AnyDesk - instalacao manual (precisa clicar em Instalar)
$atual++
Write-Host "  [$atual/$total] AnyDesk..." -ForegroundColor Yellow -NoNewline
$anydeskServico = Get-Service -Name "AnyDesk" -ErrorAction SilentlyContinue
if ($anydeskServico) {
    Write-Host " Ja instalado" -ForegroundColor Gray
    $instalados += "AnyDesk - Ja instalado"
} else {
    try {
        $anydeskTemp = "$env:TEMP\AnyDesk.exe"
        Invoke-WebRequest -Uri "$ghRelease/AnyDesk.exe" -OutFile $anydeskTemp -ErrorAction Stop
        Write-Host ""
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Yellow
        Write-Host "  ATENCAO: AnyDesk vai abrir." -ForegroundColor Yellow
        Write-Host "  Clique em 'Instalar AnyDesk' no programa." -ForegroundColor Yellow
        Write-Host "  Depois feche a janela do AnyDesk." -ForegroundColor Yellow
        Write-Host "  O script continua automaticamente." -ForegroundColor Yellow
        Write-Host "  ============================================" -ForegroundColor Yellow
        Write-Host ""
        Start-Process $anydeskTemp -Wait
        Remove-Item $anydeskTemp -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $anydeskServico = Get-Service -Name "AnyDesk" -ErrorAction SilentlyContinue
        if ($anydeskServico) {
            Write-Host "  AnyDesk instalado com sucesso!" -ForegroundColor Green
            $instalados += "AnyDesk - Instalado"
        } else {
            Write-Host "  AnyDesk pode nao ter sido instalado corretamente" -ForegroundColor Yellow
            $instalados += "AnyDesk - Verificar manualmente"
        }
    } catch {
        Write-Host " ERRO: $_" -ForegroundColor Red
        $instalados += "AnyDesk - ERRO"
        $erros += "AnyDesk"
    }
}

# ============================================
# [3] INSTALAR PROGRAMAS (via GitHub Releases)
# ============================================

Write-Host "`n[3/$etapaTotal] Instalando programas extras..." -ForegroundColor Cyan

# STL Thumb
Write-Host "  STL Thumb..." -ForegroundColor Yellow -NoNewline
try {
    $stlInstaller = "$env:TEMP\STL-Thumb.exe"
    Invoke-WebRequest -Uri "$ghRelease/STL-Thumb-Windows_0.5.0.exe" -OutFile $stlInstaller -ErrorAction Stop
    Start-Process $stlInstaller -ArgumentList "/S" -Wait -ErrorAction SilentlyContinue
    Remove-Item $stlInstaller -Force -ErrorAction SilentlyContinue
    Write-Host " OK" -ForegroundColor Green
    $instalados += "STL Thumb - Instalado"
} catch {
    Write-Host " ERRO" -ForegroundColor Red
    $instalados += "STL Thumb - ERRO"
    $erros += "STL Thumb"
}

# uTorrent Web
Write-Host "  uTorrent Web..." -ForegroundColor Yellow -NoNewline
try {
    $utInstaller = "$env:TEMP\utweb_installer.exe"
    Invoke-WebRequest -Uri "$ghRelease/utweb_installer.exe" -OutFile $utInstaller -ErrorAction Stop
    Start-Process $utInstaller -ArgumentList "/S" -Wait -ErrorAction SilentlyContinue
    Remove-Item $utInstaller -Force -ErrorAction SilentlyContinue
    Write-Host " OK" -ForegroundColor Green
    $instalados += "uTorrent Web - Instalado"
} catch {
    Write-Host " ERRO" -ForegroundColor Red
    $instalados += "uTorrent Web - ERRO"
    $erros += "uTorrent Web"
}

# ============================================
# [4] BAIXAR ARQUIVOS EXTRAS PARA O DESKTOP
# ============================================

Write-Host "`n[4/$etapaTotal] Baixando arquivos extras..." -ForegroundColor Cyan

$arquivos = @(
    @{ url = "K585.DITI.half.hand.zip";                nome = "K585 DITI half hand.zip" },
    @{ url = "Kurama.Software.e.reset.K552RGB-BRS.rar"; nome = "Kurama Software e reset K552RGB-BRS.rar" },
    @{ url = "wallpaper.opera.jpg";                     nome = "wallpaper opera.jpg" },
    @{ url = "Abrir_NVIDIA_Drivers.url";                nome = "Abrir_NVIDIA_Drivers.url" }
)

foreach ($arq in $arquivos) {
    Write-Host "  $($arq.nome)..." -ForegroundColor Yellow -NoNewline
    try {
        Invoke-WebRequest -Uri "$ghRelease/$($arq.url)" -OutFile "$desktop\$($arq.nome)" -ErrorAction Stop
        Write-Host " OK" -ForegroundColor Green
    } catch {
        Write-Host " ERRO" -ForegroundColor Red
        $erros += $arq.nome
    }
}

# ============================================
# [5] CONFIGURAR WALLPAPER E SONS
# ============================================

Write-Host "`n[5/$etapaTotal] Configurando personalizacao..." -ForegroundColor Cyan

# Baixar wallpaper e aplicar
Write-Host "  Wallpaper..." -ForegroundColor Yellow -NoNewline
try {
    $wpPath = "$env:USERPROFILE\Pictures\wallpaper-windows.jpg"
    Invoke-WebRequest -Uri "$ghRelease/wallpaper.windows.jpg" -OutFile $wpPath -UseBasicParsing -ErrorAction Stop

    # Aplicar wallpaper
    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public class Wallpaper {
        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
    }
"@
    [Wallpaper]::SystemParametersInfo(0x0014, 0, $wpPath, 0x0003) | Out-Null
    Write-Host " OK" -ForegroundColor Green
} catch {
    Write-Host " ERRO" -ForegroundColor Red
    $erros += "Wallpaper"
}

# Baixar e configurar sons USB
Write-Host "  Sons USB..." -ForegroundColor Yellow -NoNewline
try {
    $soundDir = "$env:USERPROFILE\Sounds"
    New-Item -ItemType Directory -Path $soundDir -Force | Out-Null

    Invoke-WebRequest -Uri "$ghRelease/Yamete.Kudasai.wav" -OutFile "$soundDir\Yamete Kudasai.wav" -ErrorAction Stop
    Invoke-WebRequest -Uri "$ghRelease/Kyaa.wav" -OutFile "$soundDir\Kyaa.wav" -ErrorAction Stop

    # Configurar som de USB conectado (DeviceConnect)
    $regConnect = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceConnect\.Current"
    if (-not (Test-Path $regConnect)) { New-Item -Path $regConnect -Force | Out-Null }
    Set-ItemProperty -Path $regConnect -Name "(Default)" -Value "$soundDir\Yamete Kudasai.wav"

    # Configurar som de USB desconectado (DeviceDisconnect)
    $regDisconnect = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceDisconnect\.Current"
    if (-not (Test-Path $regDisconnect)) { New-Item -Path $regDisconnect -Force | Out-Null }
    Set-ItemProperty -Path $regDisconnect -Name "(Default)" -Value "$soundDir\Kyaa.wav"

    Write-Host " OK" -ForegroundColor Green
} catch {
    Write-Host " ERRO" -ForegroundColor Red
    $erros += "Sons USB"
}

# ============================================
# RESUMO FINAL
# ============================================

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  SETUP CONCLUIDO!" -ForegroundColor Green
if ($erros.Count -gt 0) {
    Write-Host "  Erros: $($erros.Count) item(ns) falharam" -ForegroundColor Red
} else {
    Write-Host "  Tudo instalado sem erros!" -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Programas:" -ForegroundColor Cyan
foreach ($inst in $instalados) {
    Write-Host "  $inst"
}
if ($erros.Count -gt 0) {
    Write-Host "`nErros:" -ForegroundColor Red
    foreach ($e in $erros) {
        Write-Host "  ! $e" -ForegroundColor Red
    }
}
Write-Host ""
pause
