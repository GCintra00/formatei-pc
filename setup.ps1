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
$etapaTotal = 8
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

$mcafee = Get-WmiObject -Class Win32_Product -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*McAfee*" }
foreach ($m in $mcafee) { $m.Uninstall() | Out-Null; $removidos += $m.Name }

Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$onedrivePath = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $onedrivePath)) { $onedrivePath = "$env:SystemRoot\System32\OneDriveSetup.exe" }
if (Test-Path $onedrivePath) {
    Start-Process $onedrivePath -ArgumentList "/uninstall" -Wait -ErrorAction SilentlyContinue
    $removidos += "OneDrive"
}
winget uninstall --id Microsoft.OneDrive -e --silent 2>&1 | Out-Null

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
    @{ nome = "Logitech G Hub";      id = "Logitech.GHUB" },
    @{ nome = "Lightshot";           id = "Skillbrains.Lightshot" },
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

# AnyDesk - instalacao manual
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

# WinRAR
Write-Host "  WinRAR..." -ForegroundColor Yellow -NoNewline
try {
    $winrarInstaller = "$env:TEMP\winrar.exe"
    Invoke-WebRequest -Uri "$ghRelease/winrar.exe" -OutFile $winrarInstaller -ErrorAction Stop
    Start-Process $winrarInstaller -ArgumentList "/S" -Wait -ErrorAction SilentlyContinue
    Remove-Item $winrarInstaller -Force -ErrorAction SilentlyContinue
    Write-Host " OK" -ForegroundColor Green
    $instalados += "WinRAR - Instalado"
} catch {
    Write-Host " ERRO" -ForegroundColor Red
    $instalados += "WinRAR - ERRO"
    $erros += "WinRAR"
}

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
    Write-Host ""
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Yellow
    Write-Host "  ATENCAO: uTorrent Web vai abrir." -ForegroundColor Yellow
    Write-Host "  Clique: Next > Agree > Skip All > Finish" -ForegroundColor Yellow
    Write-Host "  NAO marque 'Launch uTorrent Web'" -ForegroundColor Yellow
    Write-Host "  O script continua automaticamente." -ForegroundColor Yellow
    Write-Host "  ============================================" -ForegroundColor Yellow
    Write-Host ""
    Start-Process $utInstaller -Wait
    Remove-Item $utInstaller -Force -ErrorAction SilentlyContinue
    Write-Host "  uTorrent Web instalado!" -ForegroundColor Green
    $instalados += "uTorrent Web - Instalado"
} catch {
    Write-Host " ERRO" -ForegroundColor Red
    $instalados += "uTorrent Web - ERRO"
    $erros += "uTorrent Web"
}

# ============================================
# [4] BAIXAR ARQUIVOS EXTRAS
# ============================================

Write-Host "`n[4/$etapaTotal] Baixando arquivos extras..." -ForegroundColor Cyan

# Criar pasta Kindle na Area de Trabalho e mover atalhos
$kindleDir = "$desktop\Kindle"
New-Item -ItemType Directory -Path $kindleDir -Force | Out-Null

# Mover atalhos dos programas Kindle para a pasta
$kindleApps = @("Calibre*", "HakuNeko*", "KCC*", "Kindle Previewer*", "Kindle Comic*")
$startMenuPaths = @(
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
)
foreach ($pattern in $kindleApps) {
    foreach ($smPath in $startMenuPaths) {
        Get-ChildItem -Path $smPath -Filter "$pattern.lnk" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName "$kindleDir\$($_.Name)" -Force -ErrorAction SilentlyContinue
            Write-Host "  Kindle: $($_.Name)" -ForegroundColor Green
        }
    }
}
# Criar atalhos manuais se nao encontrou no Start Menu
$calibreExe = "$env:ProgramFiles\Calibre2\calibre.exe"
if ((Test-Path $calibreExe) -and -not (Test-Path "$kindleDir\Calibre*.lnk")) {
    $shell = New-Object -ComObject WScript.Shell
    $atalho = $shell.CreateShortcut("$kindleDir\Calibre.lnk")
    $atalho.TargetPath = $calibreExe
    $atalho.Save()
    Write-Host "  Kindle: Calibre.lnk" -ForegroundColor Green
}

# Arquivos extras para o Desktop
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

# Wallpaper
Write-Host "  Wallpaper..." -ForegroundColor Yellow -NoNewline
try {
    $wpPath = "$env:USERPROFILE\Pictures\wallpaper-windows.jpg"
    Invoke-WebRequest -Uri "$ghRelease/wallpaper.windows.jpg" -OutFile $wpPath -UseBasicParsing -ErrorAction Stop
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

# Sons USB
Write-Host "  Sons USB..." -ForegroundColor Yellow -NoNewline
try {
    $soundDir = "$env:USERPROFILE\Sounds"
    New-Item -ItemType Directory -Path $soundDir -Force | Out-Null
    Invoke-WebRequest -Uri "$ghRelease/Yamete.Kudasai.wav" -OutFile "$soundDir\Yamete Kudasai.wav" -ErrorAction Stop
    Invoke-WebRequest -Uri "$ghRelease/Kyaa.wav" -OutFile "$soundDir\Kyaa.wav" -ErrorAction Stop
    $regConnect = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceConnect\.Current"
    if (-not (Test-Path $regConnect)) { New-Item -Path $regConnect -Force | Out-Null }
    Set-ItemProperty -Path $regConnect -Name "(Default)" -Value "$soundDir\Yamete Kudasai.wav"
    $regDisconnect = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceDisconnect\.Current"
    if (-not (Test-Path $regDisconnect)) { New-Item -Path $regDisconnect -Force | Out-Null }
    Set-ItemProperty -Path $regDisconnect -Name "(Default)" -Value "$soundDir\Kyaa.wav"
    Write-Host " OK" -ForegroundColor Green
} catch {
    Write-Host " ERRO" -ForegroundColor Red
    $erros += "Sons USB"
}

# ============================================
# [6] DESATIVAR NOTIFICACOES DO WINDOWS
# ============================================

Write-Host "`n[6/$etapaTotal] Desativando notificacoes..." -ForegroundColor Cyan

try {
    # Desativar notificacoes gerais
    $regNotif = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"
    if (-not (Test-Path $regNotif)) { New-Item -Path $regNotif -Force | Out-Null }
    Set-ItemProperty -Path $regNotif -Name "ToastEnabled" -Value 0 -Type DWord

    # Desativar Central de Notificacoes
    $regAction = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
    if (-not (Test-Path $regAction)) { New-Item -Path $regAction -Force | Out-Null }
    Set-ItemProperty -Path $regAction -Name "DisableNotificationCenter" -Value 1 -Type DWord

    # Desativar notificacoes na tela de bloqueio
    $regLock = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
    if (-not (Test-Path $regLock)) { New-Item -Path $regLock -Force | Out-Null }
    Set-ItemProperty -Path $regLock -Name "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND" -Value 0 -Type DWord
    Set-ItemProperty -Path $regLock -Name "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK" -Value 0 -Type DWord

    # Desativar sugestoes e dicas do Windows
    $regSugest = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    if (Test-Path $regSugest) {
        Set-ItemProperty -Path $regSugest -Name "SubscribedContent-338389Enabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regSugest -Name "SubscribedContent-310093Enabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regSugest -Name "SubscribedContent-338388Enabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $regSugest -Name "SoftLandingEnabled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    }

    Write-Host "  Notificacoes desativadas" -ForegroundColor Green
} catch {
    Write-Host "  ERRO" -ForegroundColor Red
    $erros += "Notificacoes"
}

# ============================================
# [7] LIMPAR BARRA DE TAREFAS E FIXAR PROGRAMAS
# ============================================

Write-Host "`n[7/$etapaTotal] Configurando barra de tarefas..." -ForegroundColor Cyan

try {
    # Limpar todos os itens fixados da barra de tarefas
    $taskbandPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
    Remove-Item -Path $taskbandPath -Force -Recurse -ErrorAction SilentlyContinue
    New-Item -Path $taskbandPath -Force | Out-Null

    # Remover icones padrao da barra (Win 11)
    $regAdvanced = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-ItemProperty -Path $regAdvanced -Name "ShowTaskViewButton" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regAdvanced -Name "TaskbarDa" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regAdvanced -Name "TaskbarMn" -Value 0 -Type DWord -ErrorAction SilentlyContinue

    # Desativar busca na barra de tarefas
    $regSearch = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (-not (Test-Path $regSearch)) { New-Item -Path $regSearch -Force | Out-Null }
    Set-ItemProperty -Path $regSearch -Name "SearchboxTaskbarMode" -Value 0 -Type DWord

    # Criar atalhos para fixar na barra
    $pinDir = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    New-Item -ItemType Directory -Path $pinDir -Force | Out-Null

    # Opera GX
    $operaPaths = @(
        "$env:LOCALAPPDATA\Programs\Opera GX\opera.exe",
        "$env:ProgramFiles\Opera GX\opera.exe",
        "${env:ProgramFiles(x86)}\Opera GX\opera.exe"
    )
    foreach ($p in $operaPaths) {
        if (Test-Path $p) {
            $shell = New-Object -ComObject WScript.Shell
            $atalho = $shell.CreateShortcut("$pinDir\Opera GX.lnk")
            $atalho.TargetPath = $p
            $atalho.Save()
            break
        }
    }

    # Chrome
    $chromePath = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) { $chromePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
    if (Test-Path $chromePath) {
        $shell = New-Object -ComObject WScript.Shell
        $atalho = $shell.CreateShortcut("$pinDir\Google Chrome.lnk")
        $atalho.TargetPath = $chromePath
        $atalho.Save()
    }

    # Explorador de Arquivos
    $shell = New-Object -ComObject WScript.Shell
    $atalho = $shell.CreateShortcut("$pinDir\Explorador de Arquivos.lnk")
    $atalho.TargetPath = "explorer.exe"
    $atalho.Save()

    Write-Host "  Barra de tarefas configurada" -ForegroundColor Green
    Write-Host "  (Opera GX, Chrome, Explorador)" -ForegroundColor Gray
} catch {
    Write-Host "  ERRO" -ForegroundColor Red
    $erros += "Barra de tarefas"
}

# ============================================
# [8] REMOVER AUTO-INICIO DE PROGRAMAS
# ============================================

Write-Host "`n[8/$etapaTotal] Removendo programas do inicio automatico..." -ForegroundColor Cyan

# Programas para remover do auto-inicio (manter AnyDesk)
$autoStartRemove = @("Discord", "Steam", "Epic Games", "Opera", "Bambu", "Logitech", "Lightshot", "uTorrent", "Spotify", "Microsoft Edge", "Teams")

# Limpar registro HKCU Run
$regRun = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $regRun) {
    $entries = Get-ItemProperty $regRun -ErrorAction SilentlyContinue
    foreach ($prop in $entries.PSObject.Properties) {
        if ($prop.Name -match "PS" -or $prop.Name -eq "(default)") { continue }
        foreach ($pattern in $autoStartRemove) {
            if ($prop.Name -like "*$pattern*" -or $prop.Value -like "*$pattern*") {
                Remove-ItemProperty -Path $regRun -Name $prop.Name -ErrorAction SilentlyContinue
                Write-Host "  Removido: $($prop.Name)" -ForegroundColor Green
            }
        }
    }
}

# Limpar registro HKLM Run (exceto AnyDesk)
$regRunLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $regRunLM) {
    $entries = Get-ItemProperty $regRunLM -ErrorAction SilentlyContinue
    foreach ($prop in $entries.PSObject.Properties) {
        if ($prop.Name -match "PS" -or $prop.Name -eq "(default)") { continue }
        foreach ($pattern in $autoStartRemove) {
            if ($prop.Name -like "*$pattern*" -or $prop.Value -like "*$pattern*") {
                Remove-ItemProperty -Path $regRunLM -Name $prop.Name -ErrorAction SilentlyContinue
                Write-Host "  Removido: $($prop.Name)" -ForegroundColor Green
            }
        }
    }
}

# Limpar pasta Startup
$startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
if (Test-Path $startupFolder) {
    Get-ChildItem $startupFolder -ErrorAction SilentlyContinue | ForEach-Object {
        $keep = $false
        if ($_.Name -like "*AnyDesk*") { $keep = $true }
        if (-not $keep) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  Removido: $($_.Name)" -ForegroundColor Green
        }
    }
}

Write-Host "  Auto-inicio limpo (AnyDesk mantido)" -ForegroundColor Green

# Reiniciar Explorer para aplicar mudancas na barra de tarefas
Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Process "explorer.exe"

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
