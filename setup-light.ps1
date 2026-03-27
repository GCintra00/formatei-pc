# ============================================
# FORMATEI O PC - VERSAO LIGHT
# Limpa bloatware, instala Chrome, configura
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

# Contador de uso
Invoke-RestMethod -Uri "https://script.google.com/macros/s/AKfycbwZwJrHL2SnECPzx5inz2K5_AVxbVvukXMra0grAgSbVuNjbxeNnP8sLDGdy-Sf2yfvoA/exec?script=formatei-light" -ErrorAction SilentlyContinue | Out-Null

$etapaTotal = 5
$erros = @()

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  FORMATEI O PC - VERSAO LIGHT" -ForegroundColor Cyan
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
    "Clipchamp*",
    "Dropbox*"
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
# [2] INSTALAR GOOGLE CHROME
# ============================================

Write-Host "`n[2/$etapaTotal] Instalando Google Chrome..." -ForegroundColor Cyan

Write-Host "  Google Chrome..." -ForegroundColor Yellow -NoNewline
$resultado = winget install --id Google.Chrome -e --accept-source-agreements --accept-package-agreements --silent 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host " OK" -ForegroundColor Green
} elseif ($resultado -match "already installed") {
    Write-Host " Ja instalado" -ForegroundColor Gray
} else {
    Write-Host " ERRO" -ForegroundColor Red
    $erros += "Google Chrome"
}

# ============================================
# [3] DESATIVAR NOTIFICACOES DO WINDOWS
# ============================================

Write-Host "`n[3/$etapaTotal] Desativando notificacoes..." -ForegroundColor Cyan

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

    # Desativar notificacoes de TODOS os apps
    $regWPN = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"
    Set-ItemProperty -Path $regWPN -Name "DatabaseMigrationCompleted" -Value 1 -Type DWord -ErrorAction SilentlyContinue

    # Desativar som de notificacao
    $regNotifSettings = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
    if (-not (Test-Path $regNotifSettings)) { New-Item -Path $regNotifSettings -Force | Out-Null }
    Set-ItemProperty -Path $regNotifSettings -Name "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND" -Value 0 -Type DWord
    Set-ItemProperty -Path $regNotifSettings -Name "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK" -Value 0 -Type DWord
    Set-ItemProperty -Path $regNotifSettings -Name "NOC_GLOBAL_SETTING_TOASTS_ENABLED" -Value 0 -Type DWord

    # Desativar notificacoes via politica (mais agressivo)
    $regPolicy = "HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"
    if (-not (Test-Path $regPolicy)) { New-Item -Path $regPolicy -Force | Out-Null }
    Set-ItemProperty -Path $regPolicy -Name "NoToastApplicationNotification" -Value 1 -Type DWord

    # Desativar Windows Tips/Sugestoes
    $regTips = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    if (-not (Test-Path $regTips)) { New-Item -Path $regTips -Force | Out-Null }
    Set-ItemProperty -Path $regTips -Name "DisableSoftLanding" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regTips -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -ErrorAction SilentlyContinue

    Write-Host "  Todas as notificacoes desativadas" -ForegroundColor Green
} catch {
    Write-Host "  ERRO" -ForegroundColor Red
    $erros += "Notificacoes"
}

# ============================================
# [4] LIMPAR BARRA DE TAREFAS E MENU INICIAR
# ============================================

Write-Host "`n[4/$etapaTotal] Configurando barra de tarefas..." -ForegroundColor Cyan

try {
    $regAdvanced = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

    # Remover TODOS os icones do sistema da barra de tarefas
    Set-ItemProperty -Path $regAdvanced -Name "ShowTaskViewButton" -Value 0 -Type DWord -ErrorAction SilentlyContinue  # Task View
    Set-ItemProperty -Path $regAdvanced -Name "TaskbarDa" -Value 0 -Type DWord -ErrorAction SilentlyContinue          # Widgets
    Set-ItemProperty -Path $regAdvanced -Name "TaskbarMn" -Value 0 -Type DWord -ErrorAction SilentlyContinue          # Chat/Teams
    Set-ItemProperty -Path $regAdvanced -Name "ShowCortanaButton" -Value 0 -Type DWord -ErrorAction SilentlyContinue  # Cortana

    # Remover Noticias e Interesses / Tempo (Win 10)
    try {
        $regFeeds = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds"
        New-Item -Path $regFeeds -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $regFeeds -Name "ShellFeedsTaskbarViewMode" -Value 2 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $regFeeds -Name "IsFeedsAvailable" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    } catch { }

    # Remover Widgets (Win 11) via politica
    $regWidgets = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    if (-not (Test-Path $regWidgets)) { New-Item -Path $regWidgets -Force | Out-Null }
    Set-ItemProperty -Path $regWidgets -Name "AllowNewsAndInterests" -Value 0 -Type DWord -ErrorAction SilentlyContinue

    # Desativar busca na barra de tarefas
    $regSearch = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (-not (Test-Path $regSearch)) { New-Item -Path $regSearch -Force | Out-Null }
    Set-ItemProperty -Path $regSearch -Name "SearchboxTaskbarMode" -Value 0 -Type DWord

    # Desativar Cortana via politica
    $regCortana = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    if (-not (Test-Path $regCortana)) { New-Item -Path $regCortana -Force | Out-Null }
    Set-ItemProperty -Path $regCortana -Name "AllowCortana" -Value 0 -Type DWord -ErrorAction SilentlyContinue

    # ---- LIMPAR MENU INICIAR (tiles/pins) ----

    # Win 10: Remover todos os tiles do Menu Iniciar
    $startTiles = (New-Object -Com Shell.Application).NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}')
    if ($startTiles) {
        $startTiles.Items() | ForEach-Object {
            $_.Verbs() | Where-Object { $_.Name -match "Unpin|Desafixar|Desanclar" } | ForEach-Object { $_.DoIt() }
        }
    }

    # Win 10/11: Limpar cache de tiles do registro
    $startCachePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount"
    if (Test-Path $startCachePath) {
        Get-ChildItem $startCachePath -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "start\.tilegrid" } |
            ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Win 11: Limpar layout do Menu Iniciar (remover todos os pins)
    $startLayoutPath = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState"
    if (Test-Path $startLayoutPath) {
        Remove-Item "$startLayoutPath\start*.bin" -Force -ErrorAction SilentlyContinue
        Remove-Item "$startLayoutPath\start2.bin" -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Menu Iniciar limpo" -ForegroundColor Green

    # Limpar TODOS os itens fixados na barra de tarefas
    $pinDir = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $pinDir) {
        Remove-Item "$pinDir\*" -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $pinDir -Force | Out-Null

    # Limpar taskband do registro
    $taskbandPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
    Remove-Item -Path $taskbandPath -Force -Recurse -ErrorAction SilentlyContinue
    New-Item -Path $taskbandPath -Force | Out-Null

    # Desafixar Microsoft Edge e Microsoft Store da barra
    $regPins = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband\AuxilliaryPins"
    Remove-Item -Path $regPins -Force -Recurse -ErrorAction SilentlyContinue

    # Fixar Chrome na barra
    $chromePath = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) { $chromePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe" }
    if (Test-Path $chromePath) {
        $shell = New-Object -ComObject WScript.Shell
        $atalho = $shell.CreateShortcut("$pinDir\01-Google Chrome.lnk")
        $atalho.TargetPath = $chromePath
        $atalho.Save()

        $shellApp = New-Object -ComObject Shell.Application
        $dir = $shellApp.Namespace((Split-Path $chromePath))
        $item = $dir.ParseName((Split-Path $chromePath -Leaf))
        $item.Verbs() | Where-Object { $_.Name -match "taskbar|barra de tarefas|Fixar na barra" } | ForEach-Object { $_.DoIt() }
        Write-Host "  Fixado: Chrome" -ForegroundColor Green
    }

    # Fixar Explorador de Arquivos
    $shell = New-Object -ComObject WScript.Shell
    $atalho = $shell.CreateShortcut("$pinDir\02-Explorador de Arquivos.lnk")
    $atalho.TargetPath = "explorer.exe"
    $atalho.Save()

    $shellApp = New-Object -ComObject Shell.Application
    $explorerDir = $shellApp.Namespace("$env:WINDIR")
    $explorerItem = $explorerDir.ParseName("explorer.exe")
    $explorerItem.Verbs() | Where-Object { $_.Name -match "taskbar|barra de tarefas|Fixar na barra" } | ForEach-Object { $_.DoIt() }
    Write-Host "  Fixado: Explorador de Arquivos" -ForegroundColor Green

    Write-Host "  Barra limpa e configurada" -ForegroundColor Green
} catch {
    Write-Host "  ERRO na barra: $_" -ForegroundColor Red
    $erros += "Barra de tarefas"
}

# ============================================
# [5] REMOVER AUTO-INICIO DE PROGRAMAS
# ============================================

Write-Host "`n[5/$etapaTotal] Removendo programas do inicio automatico..." -ForegroundColor Cyan

# Itens que DEVEM permanecer no auto-inicio
$manter = @("SecurityHealth", "RtkAudUService")

# Limpar HKCU Run (remover TUDO exceto os mantidos)
$regRun = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $regRun) {
    $entries = Get-ItemProperty $regRun -ErrorAction SilentlyContinue
    foreach ($prop in $entries.PSObject.Properties) {
        if ($prop.Name -match "^PS" -or $prop.Name -eq "(default)") { continue }
        $keep = $false
        foreach ($m in $manter) { if ($prop.Name -like "*$m*") { $keep = $true } }
        if (-not $keep) {
            Remove-ItemProperty -Path $regRun -Name $prop.Name -ErrorAction SilentlyContinue
            Write-Host "  Removido HKCU: $($prop.Name)" -ForegroundColor Green
        }
    }
}

# Limpar HKLM Run (remover TUDO exceto mantidos)
$regRunLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $regRunLM) {
    $entries = Get-ItemProperty $regRunLM -ErrorAction SilentlyContinue
    foreach ($prop in $entries.PSObject.Properties) {
        if ($prop.Name -match "^PS" -or $prop.Name -eq "(default)") { continue }
        $keep = $false
        foreach ($m in $manter) { if ($prop.Name -like "*$m*") { $keep = $true } }
        if (-not $keep) {
            Remove-ItemProperty -Path $regRunLM -Name $prop.Name -ErrorAction SilentlyContinue
            Write-Host "  Removido HKLM: $($prop.Name)" -ForegroundColor Green
        }
    }
}

# Limpar pasta Startup do usuario (tudo)
$startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
if (Test-Path $startupFolder) {
    Get-ChildItem $startupFolder -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Host "  Removido Startup: $($_.Name)" -ForegroundColor Green
    }
}

# Limpar pasta Common Startup (todos os usuarios)
$commonStartup = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
if (Test-Path $commonStartup) {
    Get-ChildItem $commonStartup -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Host "  Removido Common Startup: $($_.Name)" -ForegroundColor Green
    }
}

# Desativar auto-inicio via Task Manager (Approved entries)
$permitidos = @("SecurityHealth", "RtkAudUService")
$disabledBytes = [byte[]](0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)

# StartupApproved HKCU
$regApproved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
if (Test-Path $regApproved) {
    (Get-Item $regApproved).GetValueNames() | ForEach-Object {
        if ($_ -eq "(default)") { return }
        $permitido = $false
        foreach ($p in $permitidos) { if ($_ -like "*$p*") { $permitido = $true } }
        if (-not $permitido) {
            Set-ItemProperty -Path $regApproved -Name $_ -Value $disabledBytes -Type Binary -ErrorAction SilentlyContinue
            Write-Host "  Desativado startup: $_" -ForegroundColor Green
        }
    }
}

# StartupApproved HKLM
$regApprovedLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
if (Test-Path $regApprovedLM) {
    (Get-Item $regApprovedLM).GetValueNames() | ForEach-Object {
        if ($_ -eq "(default)") { return }
        $permitido = $false
        foreach ($p in $permitidos) { if ($_ -like "*$p*") { $permitido = $true } }
        if (-not $permitido) {
            Set-ItemProperty -Path $regApprovedLM -Name $_ -Value $disabledBytes -Type Binary -ErrorAction SilentlyContinue
            Write-Host "  Desativado startup HKLM: $_" -ForegroundColor Green
        }
    }
}

# StartupApproved\StartupFolder
$regApprovedFolder = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder"
if (Test-Path $regApprovedFolder) {
    (Get-Item $regApprovedFolder).GetValueNames() | ForEach-Object {
        if ($_ -eq "(default)") { return }
        $permitido = $false
        foreach ($p in $permitidos) { if ($_ -like "*$p*") { $permitido = $true } }
        if (-not $permitido) {
            Set-ItemProperty -Path $regApprovedFolder -Name $_ -Value $disabledBytes -Type Binary -ErrorAction SilentlyContinue
            Write-Host "  Desativado startup folder: $_" -ForegroundColor Green
        }
    }
}

# Remover OneDrive do auto-inicio (persistente)
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSetup" -ErrorAction SilentlyContinue

# Desativar TODAS as tarefas agendadas de logon (exceto do sistema)
$tarefasManter = @("MicrosoftEdgeUpdateTask", "SecurityHealth", "Windows", "Microsoft\Windows")
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.Triggers | Where-Object { $_ -is [Microsoft.Management.Infrastructure.CimInstance] -and $_.CimClass.CimClassName -eq "MSFT_TaskLogonTrigger" }
} | ForEach-Object {
    $skip = $false
    foreach ($m in $tarefasManter) { if ($_.TaskPath -like "*$m*") { $skip = $true } }
    if (-not $skip) {
        Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
        Write-Host "  Tarefa desativada: $($_.TaskName)" -ForegroundColor Green
    }
}

Write-Host "  Auto-inicio limpo" -ForegroundColor Green

# Nao reiniciar Explorer (abre janela indesejada). Mudancas aplicam no proximo reinicio do PC.

# ============================================
# RESUMO FINAL
# ============================================

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  SETUP LIGHT CONCLUIDO!" -ForegroundColor Green
if ($erros.Count -gt 0) {
    Write-Host "  Erros: $($erros.Count) item(ns) falharam" -ForegroundColor Red
} else {
    Write-Host "  Tudo concluido sem erros!" -ForegroundColor Green
}
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Resumo:" -ForegroundColor Cyan
Write-Host "  [1] Bloatware removido"
Write-Host "  [2] Google Chrome instalado"
Write-Host "  [3] Notificacoes desativadas"
Write-Host "  [4] Barra de tarefas limpa"
Write-Host "  [5] Auto-inicio limpo"
if ($erros.Count -gt 0) {
    Write-Host "`nErros:" -ForegroundColor Red
    foreach ($e in $erros) {
        Write-Host "  ! $e" -ForegroundColor Red
    }
}
Write-Host ""
pause
