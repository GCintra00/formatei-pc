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

# Manter PC acordado durante toda a execucao do script
try {
    $sig = '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    $sleepHelper = Add-Type -MemberDefinition $sig -Name "Sleep" -Namespace "Win32" -PassThru -ErrorAction SilentlyContinue
    if ($sleepHelper) { $sleepHelper::SetThreadExecutionState(0x80000003) | Out-Null }
} catch {}

# Forcar TLS 1.2 (Windows 10 antigo usa TLS 1.0 e GitHub rejeita)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================
# Log automatico em Downloads
# ============================================
$logTimestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logPath = "$env:USERPROFILE\Downloads\formatei-pc-log_$logTimestamp.txt"
try {
    Start-Transcript -Path $logPath -Force -ErrorAction Stop | Out-Null
    $logAtivo = $true
} catch { $logAtivo = $false }

Write-Host "========================================" -ForegroundColor DarkGray
Write-Host "  FORMATEI PC - LOG INICIADO" -ForegroundColor DarkGray
Write-Host "  $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor DarkGray
if ($logAtivo) { Write-Host "  Log: $logPath" -ForegroundColor DarkGray }
Write-Host "  PC: $env:COMPUTERNAME | User: $env:USERNAME" -ForegroundColor DarkGray
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host "  OS: $($os.Caption) (build $($os.BuildNumber))" -ForegroundColor DarkGray
} catch {}
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Host "  HW: $($cs.Manufacturer) $($cs.Model)" -ForegroundColor DarkGray
} catch {}
Write-Host "========================================" -ForegroundColor DarkGray
Write-Host ""

# Helper de download com timeout REAL (BITS, fallback curl.exe)
function Download-File {
    param([string]$Url, [string]$OutPath, [int]$TimeoutSec = 180)
    try {
        $job = Start-BitsTransfer -Source $Url -Destination $OutPath -Asynchronous -ErrorAction Stop
        $start = Get-Date
        while ($job.JobState -in 'Connecting','Transferring','Queued') {
            if (((Get-Date) - $start).TotalSeconds -gt $TimeoutSec) {
                Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
                return $false
            }
            Start-Sleep -Seconds 2
        }
        if ($job.JobState -eq 'Transferred') {
            Complete-BitsTransfer -BitsJob $job
            return (Test-Path $OutPath) -and ((Get-Item $OutPath).Length -gt 0)
        } else {
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
        }
    } catch {}
    $curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curlExe) {
        $p = Start-Process curl.exe -ArgumentList @("-L","-s","--max-time","$TimeoutSec","-o","`"$OutPath`"","`"$Url`"") -PassThru -Wait -NoNewWindow
        if ($p.ExitCode -eq 0 -and (Test-Path $OutPath) -and ((Get-Item $OutPath).Length -gt 0)) { return $true }
    }
    return $false
}

# Corrigir DNS
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
    Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4") -ErrorAction SilentlyContinue
}
Write-Host "DNS configurado (Google 8.8.8.8)" -ForegroundColor Gray

# Contador de uso
Invoke-RestMethod -Uri "https://script.google.com/macros/s/AKfycbwZwJrHL2SnECPzx5inz2K5_AVxbVvukXMra0grAgSbVuNjbxeNnP8sLDGdy-Sf2yfvoA/exec?script=formatei-pc" -ErrorAction SilentlyContinue | Out-Null

$desktop = [Environment]::GetFolderPath("Desktop")
$etapaTotal = 9
$erros = @()
$instalados = @()
$ghRelease = "https://github.com/GCintra00/formatei-pc/releases/download/v1.0"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  FORMATEI O PC E AGORA O QUE FAZER?" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ============================================
# [0] VERIFICAR/INSTALAR WINGET
# ============================================

function Test-WingetWorking {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
    try {
        $null = winget --version 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        $sourceTest = winget source list 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        return $true
    } catch { return $false }
}

function Install-WingetBootstrap {
    Write-Host "  Bootstrap do winget (App Installer)..." -ForegroundColor Yellow
    $tempDir = "$env:TEMP\winget-bootstrap"
    if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null }
    try {
        Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" -OutFile "$tempDir\vclibs.appx" -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx" -OutFile "$tempDir\uixaml.appx" -UseBasicParsing -ErrorAction Stop
        Invoke-WebRequest -Uri "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" -OutFile "$tempDir\winget.msixbundle" -UseBasicParsing -ErrorAction Stop
        Add-AppxPackage -Path "$tempDir\vclibs.appx" -ErrorAction SilentlyContinue
        Add-AppxPackage -Path "$tempDir\uixaml.appx" -ErrorAction SilentlyContinue
        Add-AppxPackage -Path "$tempDir\winget.msixbundle" -ErrorAction Stop
        Write-Host "  Bootstrap concluido" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  Bootstrap falhou: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

if (-not (Test-WingetWorking)) {
    Write-Host "`nWinget nao detectado ou nao funcional. Tentando bootstrap..." -ForegroundColor Yellow
    if (Install-WingetBootstrap) {
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        Start-Sleep -Seconds 3
        if (Test-WingetWorking) { winget source update 2>&1 | Out-Null }
    }
}

$hasWinget = Test-WingetWorking
if (-not $hasWinget) {
    Write-Host "  AVISO: Winget continua indisponivel. Programas serao pulados ou usarao fallback direto." -ForegroundColor Yellow
}

# Desabilita fonte msstore (causa erro 0x8a15005e em PCs com cert vencido)
if ($hasWinget) {
    try {
        $msstoreCheck = winget source list 2>&1 | Out-String
        if ($msstoreCheck -match "msstore") {
            winget source remove msstore 2>&1 | Out-Null
            Write-Host "  Fonte msstore desabilitada (workaround pra cert vencido)" -ForegroundColor DarkGray
        }
    } catch {}
}

# ============================================
# [1] REMOVER BLOATWARE
# ============================================

Write-Host "`n[1/$etapaTotal] Removendo bloatware..." -ForegroundColor Cyan

# Derrubar processos que podem interferir na remocao
$processosMatar = @(
    "McAfee*", "mcshield", "mcuicnt", "McUICnt", "ModuleCoreService", "MMSSHOST", "McPvTray",
    "OneDrive", "OneDriveSetup",
    "ms-teams", "Teams",
    "Dropbox", "DropboxUpdate",
    "WebAdvisor", "mcwebadvisor"
)
foreach ($proc in $processosMatar) {
    Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Write-Host "  Processos bloatware encerrados" -ForegroundColor Green

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
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
                    $removidos += $_.DisplayName
                }
        }
    }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $app } |
        ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null
        }
}

# McAfee: desativar servicos para nao reabrir, matar tudo
Write-Host "  McAfee: parando servicos..." -ForegroundColor Yellow
Get-Service -DisplayName "*McAfee*" -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
    Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
}
function Kill-McAfee {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "mcafee|mcshield|mcuicnt|ModuleCore|MMSSHOST|McPvTray|WebAdvisor|McInstaller|mfemms|mfevtps|mcods|mfefire|mfetp|protectedmodulehost"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
}
Kill-McAfee

$mcafeeIds = @("McAfee.WebAdvisor", "McAfee.McAfee", "McAfee.LiveSafe", "McAfee.TrueKey", "McAfee.SecurityScan")
if ($hasWinget) {
foreach ($mid in $mcafeeIds) {
    Kill-McAfee
    Write-Host "  McAfee: $mid..." -ForegroundColor Yellow -NoNewline
    $p = Start-Process "winget" -ArgumentList "uninstall --id $mid -e --silent --force --disable-interactivity" -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if ($p) {
        if (-not $p.WaitForExit(15000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            Kill-McAfee
            Write-Host " timeout (forcado)" -ForegroundColor Yellow
        } else {
            Write-Host " OK" -ForegroundColor Green
        }
    } else {
        Write-Host " nao encontrado" -ForegroundColor Gray
    }
}
} # fim if hasWinget McAfee

# === Deep clean McAfee residual (WPS + WebAdvisor + tarefas + pastas) ===
Write-Host "  McAfee: limpeza profunda silenciosa..." -ForegroundColor Yellow

$tasksRemoved = 0
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "*McAfee*" -or $_.TaskPath -like "*McAfee*" } | ForEach-Object {
    try {
        Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction Stop
        $tasksRemoved++
    } catch {}
}
if ($tasksRemoved -gt 0) { Write-Host "    $tasksRemoved tarefa(s) agendada(s) apagada(s)" -ForegroundColor DarkGray }

$uninstKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$found = Get-ItemProperty $uninstKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*McAfee*" }
foreach ($app in $found) {
    $unins = $app.QuietUninstallString
    if (-not $unins) { $unins = $app.UninstallString }
    if ($unins) {
        try {
            if ($unins -match '^"([^"]+)"\s*(.*)$') { $exe = $matches[1]; $argStr = $matches[2] }
            else { $tk = $unins -split ' ',2; $exe = $tk[0]; $argStr = if ($tk.Count -gt 1) { $tk[1] } else { '' } }
            if ($argStr -notmatch '/quiet|/qn|/silent|/S\b') { $argStr = "$argStr /quiet /norestart" }
            if (Test-Path $exe) {
                $p = Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
                if ($p) {
                    if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch {} }
                    Write-Host "    desinstalado: $($app.DisplayName)" -ForegroundColor DarkGray
                }
            }
        } catch {}
    }
}

$mcafeePaths = @("$env:ProgramFiles\McAfee","${env:ProgramFiles(x86)}\McAfee","$env:ProgramData\McAfee","$env:LOCALAPPDATA\McAfee","$env:APPDATA\McAfee")
foreach ($p in $mcafeePaths) {
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}

if (Get-Service -Name "McAfee WebAdvisor" -ErrorAction SilentlyContinue) {
    Start-Process sc.exe -ArgumentList "delete `"McAfee WebAdvisor`"" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "  McAfee: concluido" -ForegroundColor Green

# Matar TUDO via taskkill (nao trava em processos protegidos)
$matarNomes = @("OneDrive","OneDriveSetup","ms-teams","Teams","Dropbox","DropboxUpdate","mcafee*","McUICnt","mcshield","ModuleCoreService","MMSSHOST","McPvTray","WebAdvisor","mfemms","mfevtps","protectedmodulehost")
foreach ($nome in $matarNomes) {
    Start-Process "taskkill" -ArgumentList "/f /im $nome.exe" -WindowStyle Hidden -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

# OneDrive (timeout 15s)
Write-Host "  OneDrive..." -ForegroundColor Yellow -NoNewline
$onedrivePath = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $onedrivePath)) { $onedrivePath = "$env:SystemRoot\System32\OneDriveSetup.exe" }
if (Test-Path $onedrivePath) {
    $proc = Start-Process $onedrivePath -ArgumentList "/uninstall" -PassThru -ErrorAction SilentlyContinue
    if ($proc -and -not $proc.WaitForExit(15000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $removidos += "OneDrive"
}
if ($hasWinget) {
    $p = Start-Process "winget" -ArgumentList "uninstall --id Microsoft.OneDrive -e --silent --force --disable-interactivity" -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if ($p -and -not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
Write-Host " OK" -ForegroundColor Green

# Teams (timeout 15s)
Write-Host "  Teams..." -ForegroundColor Yellow -NoNewline
if ($hasWinget) {
    $p = Start-Process "winget" -ArgumentList "uninstall --id Microsoft.Teams -e --silent --force --disable-interactivity" -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if ($p -and -not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
$teamsPath = "$env:LOCALAPPDATA\Microsoft\Teams\Update.exe"
if (Test-Path $teamsPath) {
    $proc = Start-Process $teamsPath -ArgumentList "--uninstall -s" -PassThru -ErrorAction SilentlyContinue
    if ($proc -and -not $proc.WaitForExit(15000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $removidos += "Teams"
}
Write-Host " OK" -ForegroundColor Green

# Dropbox (timeout 15s)
Write-Host "  Dropbox..." -ForegroundColor Yellow -NoNewline
if ($hasWinget) {
    $p = Start-Process "winget" -ArgumentList "uninstall --id Dropbox.Dropbox -e --silent --force --disable-interactivity" -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if ($p -and -not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
Write-Host " OK" -ForegroundColor Green

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
    @{ nome = "Kindle Previewer";    id = "Amazon.KindlePreviewer" },
    @{ nome = "MSI Afterburner";    id = "Guru3D.Afterburner" }
)

$total = $programas.Count + 1  # +1 para AnyDesk
$atual = 0

foreach ($prog in $programas) {
    $atual++
    Write-Host "  [$atual/$total] $($prog.nome)..." -ForegroundColor Yellow -NoNewline

    if (-not $hasWinget) {
        Write-Host " PULADO (sem winget)" -ForegroundColor Yellow
        $instalados += "$($prog.nome) - PULADO (sem winget)"
        $erros += $prog.nome
        continue
    }

    $resultado = winget install --id $prog.id -e --accept-source-agreements --accept-package-agreements --silent 2>&1
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        Write-Host " OK" -ForegroundColor Green
        $instalados += "$($prog.nome) - Instalado"
    } elseif ($resultado -match "already installed|ja esta instalado") {
        Write-Host " Ja instalado" -ForegroundColor Gray
        $instalados += "$($prog.nome) - Ja instalado"
    } else {
        # Retry com --source winget explicito
        $resultado2 = winget install --id $prog.id -e --source winget --accept-source-agreements --accept-package-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host " OK (retry com source winget)" -ForegroundColor Green
            $instalados += "$($prog.nome) - Instalado (retry)"
        } else {
            # Fallback especifico: Chrome -> MSI direto do Google
            $fallbackInstalled = $false
            if ($prog.id -eq 'Google.Chrome') {
                Write-Host ""
                Write-Host "    [fallback] Baixando Chrome MSI direto do Google (timeout 4 min)..." -ForegroundColor DarkYellow
                $chromeMsi = "$env:TEMP\chrome_installer.msi"
                if (Test-Path $chromeMsi) { Remove-Item $chromeMsi -Force -ErrorAction SilentlyContinue }
                if (Download-File "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi" $chromeMsi 240) {
                    $sizeMB = [math]::Round((Get-Item $chromeMsi).Length / 1MB, 1)
                    Write-Host "    [fallback] Download OK ($sizeMB MB). Instalando MSI (timeout 3 min)..." -ForegroundColor DarkYellow
                    $p = Start-Process "msiexec.exe" -ArgumentList "/i `"$chromeMsi`" /qn /norestart" -PassThru
                    if (-not $p.WaitForExit(180000)) {
                        $p.Kill()
                        Write-Host "    [fallback] TIMEOUT (>3 min)" -ForegroundColor Red
                    } elseif ($p.ExitCode -eq 0) {
                        $fallbackInstalled = $true
                    }
                    Remove-Item $chromeMsi -ErrorAction SilentlyContinue
                }
            }

            if ($fallbackInstalled) {
                Write-Host "    [fallback] => OK" -ForegroundColor Green
                $instalados += "$($prog.nome) - Instalado (fallback)"
            } else {
                $errMsg = ($resultado -join " ") -replace "\s+", " "
                if ($errMsg.Length -gt 200) { $errMsg = $errMsg.Substring(0, 200) + "..." }
                Write-Host " ERRO (exit $code)" -ForegroundColor Red
                Write-Host "    $errMsg" -ForegroundColor DarkRed
                $instalados += "$($prog.nome) - ERRO: $errMsg"
                $erros += $prog.nome
            }
        }
    }
}

# AnyDesk - baixar para pasta Downloads Setup
$atual++
Write-Host "  [$atual/$total] AnyDesk..." -ForegroundColor Yellow -NoNewline
$anydeskServico = Get-Service -Name "AnyDesk" -ErrorAction SilentlyContinue
if ($anydeskServico) {
    Write-Host " Ja instalado" -ForegroundColor Gray
    $instalados += "AnyDesk - Ja instalado"
} else {
    try {
        $dlDir = "$desktop\Downloads Setup"
        New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
        Invoke-WebRequest -Uri "$ghRelease/AnyDesk.exe" -OutFile "$dlDir\AnyDesk.exe" -ErrorAction Stop
        Write-Host " Baixado (instalar manualmente)" -ForegroundColor Green
        $instalados += "AnyDesk - Baixado em Downloads Setup"
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
    Invoke-WebRequest -Uri "$ghRelease/winrar-x64-711br.exe" -OutFile $winrarInstaller -ErrorAction Stop
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

# uTorrent Web - baixar para pasta Downloads Setup
Write-Host "  uTorrent Web..." -ForegroundColor Yellow -NoNewline
try {
    $dlDir = "$desktop\Downloads Setup"
    New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
    Invoke-WebRequest -Uri "$ghRelease/utweb_installer.exe" -OutFile "$dlDir\uTorrent Web.exe" -ErrorAction Stop
    Write-Host " Baixado (instalar manualmente)" -ForegroundColor Green
    $instalados += "uTorrent Web - Baixado em Downloads Setup"
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
$dlDir = "$desktop\Downloads Setup"
New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
$kindleDir = "$dlDir\Kindle"
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

# Criar pasta de downloads na Area de Trabalho
$dlDir = "$desktop\Downloads Setup"
New-Item -ItemType Directory -Path $dlDir -Force | Out-Null

$arquivos = @(
    @{ url = "K585.DITI.half.hand.zip";                nome = "K585 DITI half hand.zip" },
    @{ url = "Kurama.Software.e.reset.K552RGB-BRS.rar"; nome = "Kurama Software e reset K552RGB-BRS.rar" },
    @{ url = "wallpaper.opera.jpg";                     nome = "wallpaper opera.jpg" },
    @{ url = "Abrir_NVIDIA_Drivers.url";                nome = "Abrir_NVIDIA_Drivers.url" },
    @{ url = "WinKeygen.rar";                           nome = "WinKeygen.rar" }
)

foreach ($arq in $arquivos) {
    Write-Host "  $($arq.nome)..." -ForegroundColor Yellow -NoNewline
    try {
        Invoke-WebRequest -Uri "$ghRelease/$($arq.url)" -OutFile "$dlDir\$($arq.nome)" -ErrorAction Stop
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
# [7] LIMPAR BARRA DE TAREFAS E FIXAR PROGRAMAS
# ============================================

Write-Host "`n[7/$etapaTotal] Configurando barra de tarefas..." -ForegroundColor Cyan

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

    # Limpar TODOS os itens fixados na barra de tarefas (deixar vazia)
    $pinDir = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $pinDir) {
        Remove-Item "$pinDir\*" -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $pinDir -Force | Out-Null

    # Limpar taskband do registro
    $taskbandPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
    Remove-Item -Path $taskbandPath -Force -Recurse -ErrorAction SilentlyContinue
    New-Item -Path $taskbandPath -Force | Out-Null

    # Desafixar Edge e Store
    $regPins = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband\AuxilliaryPins"
    Remove-Item -Path $regPins -Force -Recurse -ErrorAction SilentlyContinue

    Write-Host "  Barra de tarefas limpa (vazia)" -ForegroundColor Green
} catch {
    Write-Host "  ERRO na barra: $_" -ForegroundColor Red
    $erros += "Barra de tarefas"
}

# ============================================
# [8] REMOVER AUTO-INICIO DE PROGRAMAS
# ============================================

Write-Host "`n[8/$etapaTotal] Configurando energia..." -ForegroundColor Cyan

# AC (carregador): nada apaga / nao dorme
powercfg /change monitor-timeout-ac 0 2>&1 | Out-Null
powercfg /change standby-timeout-ac 0 2>&1 | Out-Null
powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
Write-Host "  AC (carregador): nunca apaga tela, nunca dorme" -ForegroundColor Green

# Bateria: tela apaga em 30 min, NAO dorme
powercfg /change monitor-timeout-dc 30 2>&1 | Out-Null
powercfg /change standby-timeout-dc 0 2>&1 | Out-Null
powercfg /change hibernate-timeout-dc 0 2>&1 | Out-Null
Write-Host "  Bateria: tela apaga em 30 min, sem sleep" -ForegroundColor Green

# Botoes: Power button -> shutdown | Lid close -> sleep
powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3 2>&1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3 2>&1 | Out-Null
powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1 2>&1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1 2>&1 | Out-Null
Write-Host "  Botao Power = desligar | Fechar tampa = sleep (volta ao abrir)" -ForegroundColor Green

# Hibernacao off + Modern Standby off + wake devices off (shutdown real, LED apaga)
powercfg /hibernate off 2>&1 | Out-Null
REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /V HiberbootEnabled /T REG_DWORD /D 0 /F 2>&1 | Out-Null
REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Power" /V PlatformAoAcOverride /T REG_DWORD /D 0 /F 2>&1 | Out-Null
Write-Host "  Hibernacao + Fast Startup + Modern Standby desabilitados" -ForegroundColor Green

try {
    $wakeDevices = powercfg /devicequery wake_armed 2>&1 | Where-Object { $_ -and $_ -notmatch 'NONE|------' }
    $disabled = 0
    foreach ($dev in $wakeDevices) {
        $d = "$dev".Trim()
        if ($d) { powercfg /devicedisablewake "$d" 2>&1 | Out-Null; $disabled++ }
    }
    if ($disabled -gt 0) { Write-Host "  $disabled dispositivo(s) impedido(s) de acordar o PC" -ForegroundColor Green }
} catch {}

powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null


Write-Host "`n[9/$etapaTotal] Removendo programas do inicio automatico..." -ForegroundColor Cyan

# Itens que DEVEM permanecer no auto-inicio
$manter = @("SecurityHealth", "RtkAudUService", "Lightshot")

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

# Limpar HKLM Run (remover TUDO exceto mantidos, corrigir AnyDesk)
$regRunLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path $regRunLM) {
    $entries = Get-ItemProperty $regRunLM -ErrorAction SilentlyContinue
    foreach ($prop in $entries.PSObject.Properties) {
        if ($prop.Name -match "^PS" -or $prop.Name -eq "(default)") { continue }
        $keep = $false
        foreach ($m in $manter) { if ($prop.Name -like "*$m*") { $keep = $true } }
        if ($prop.Name -like "*AnyDesk*") { $keep = $true }
        if (-not $keep) {
            Remove-ItemProperty -Path $regRunLM -Name $prop.Name -ErrorAction SilentlyContinue
            Write-Host "  Removido HKLM: $($prop.Name)" -ForegroundColor Green
        }
    }
}

# Corrigir AnyDesk para executar em segundo plano (--control)
$anydeskPaths = @(
    "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
    "${env:ProgramFiles(x86)}\AnyDesk\AnyDesk.exe"
)
foreach ($adPath in $anydeskPaths) {
    if (Test-Path $adPath) {
        Set-ItemProperty -Path $regRunLM -Name "AnyDesk" -Value "`"$adPath`" --control" -ErrorAction SilentlyContinue
        Write-Host "  AnyDesk configurado em segundo plano (--control)" -ForegroundColor Green
        break
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

# Limpar pasta Common Startup (todos os usuarios) - remover AnyDesk duplicado
$commonStartup = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
if (Test-Path $commonStartup) {
    Get-ChildItem $commonStartup -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        Write-Host "  Removido Common Startup: $($_.Name)" -ForegroundColor Green
    }
}

# Desativar auto-inicio via Task Manager (Approved entries)
$regApproved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
if (Test-Path $regApproved) {
    $entries = Get-Item $regApproved -ErrorAction SilentlyContinue
    foreach ($name in $entries.GetValueNames()) {
        $keep = $false
        foreach ($m in $manter) { if ($name -like "*$m*") { $keep = $true } }
        if ($name -like "*AnyDesk*") { $keep = $true }
        if (-not $keep -and $name -ne "(default)") {
            # Desativar setando os primeiros bytes para 03 (disabled)
            $bytes = [byte[]](0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)
            Set-ItemProperty -Path $regApproved -Name $name -Value $bytes -Type Binary -ErrorAction SilentlyContinue
            Write-Host "  Desativado: $name" -ForegroundColor Green
        }
    }
}

# Mesmo para HKLM
$regApprovedLM = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
if (Test-Path $regApprovedLM) {
    $entries = Get-Item $regApprovedLM -ErrorAction SilentlyContinue
    foreach ($name in $entries.GetValueNames()) {
        $keep = $false
        foreach ($m in $manter) { if ($name -like "*$m*") { $keep = $true } }
        if ($name -like "*AnyDesk*") { $keep = $true }
        if (-not $keep -and $name -ne "(default)") {
            $bytes = [byte[]](0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)
            Set-ItemProperty -Path $regApprovedLM -Name $name -Value $bytes -Type Binary -ErrorAction SilentlyContinue
            Write-Host "  Desativado HKLM: $name" -ForegroundColor Green
        }
    }
}

# Remover OneDrive do auto-inicio (persistente)
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSetup" -ErrorAction SilentlyContinue

# Discord: desativar auto-inicio na config do app (ele se auto-repara no registro)
$discordSettings = "$env:APPDATA\discord\settings.json"
if (Test-Path $discordSettings) {
    try {
        $json = Get-Content $discordSettings -Raw | ConvertFrom-Json
        $json | Add-Member -NotePropertyName "OPEN_ON_STARTUP" -NotePropertyValue $false -Force
        $json | Add-Member -NotePropertyName "START_MINIMIZED" -NotePropertyValue $true -Force
        $json | ConvertTo-Json -Depth 10 | Set-Content $discordSettings -Encoding UTF8
        Write-Host "  Discord auto-inicio desativado na config" -ForegroundColor Green
    } catch { }
}

# Steam: desativar auto-inicio na config
$steamCfg = "${env:ProgramFiles(x86)}\Steam\config\SteamAppData.vdf"
# Remover via registro novamente (alguns apps recriam na primeira execucao)
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Discord" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "com.squirrel.slack.slack" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Steam" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "EpicGamesLauncher" -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "LGHUB" -ErrorAction SilentlyContinue

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

# Desativar TODOS os itens do Gerenciador de Tarefas (Startup tab) exceto permitidos
$permitidos = @("SecurityHealth", "RtkAudUService", "AnyDesk", "Lightshot")
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

Write-Host "  Auto-inicio limpo (AnyDesk + Lightshot mantidos)" -ForegroundColor Green

# Nao reiniciar Explorer (abre janela do explorador). Mudancas aplicam no proximo reinicio do PC.

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

if ($logAtivo) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor DarkGray
    Write-Host "  LOG SALVO EM:" -ForegroundColor Green
    Write-Host "  $logPath" -ForegroundColor Green
    Write-Host "  (Se algo der errado, mande esse arquivo para diagnostico)" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch {}
}

Write-Host ""
pause
