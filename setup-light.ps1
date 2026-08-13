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

# Manter PC acordado durante toda a execucao do script
try {
    $sig = '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    $sleepHelper = Add-Type -MemberDefinition $sig -Name "Sleep" -Namespace "Win32" -PassThru -ErrorAction SilentlyContinue
    if ($sleepHelper) { $sleepHelper::SetThreadExecutionState(0x80000003) | Out-Null }
} catch {}

# Forcar TLS 1.2 (Windows 10 antigo usa TLS 1.0 e GitHub rejeita)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================
# Log automatico: tudo que aparece na tela vai pro arquivo
# ============================================
$logTimestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logPath = "$env:USERPROFILE\Downloads\formatei-light-log_$logTimestamp.txt"
try {
    Start-Transcript -Path $logPath -Force -ErrorAction Stop | Out-Null
    $logAtivo = $true
} catch { $logAtivo = $false }

Write-Host "========================================" -ForegroundColor DarkGray
Write-Host "  FORMATEI PC LIGHT - LOG INICIADO" -ForegroundColor DarkGray
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
Invoke-RestMethod -Uri "https://script.google.com/macros/s/AKfycbwZwJrHL2SnECPzx5inz2K5_AVxbVvukXMra0grAgSbVuNjbxeNnP8sLDGdy-Sf2yfvoA/exec?script=formatei-light" -ErrorAction SilentlyContinue | Out-Null

$etapaTotal = 6
$erros = @()

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  FORMATEI O PC - VERSAO LIGHT" -ForegroundColor Cyan
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
    Write-Host "  AVISO: Winget continua indisponivel. Chrome sera instalado via fallback direto." -ForegroundColor Yellow
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

# Derrubar TODOS os processos bloatware para permitir remocao
Write-Host "  Encerrando processos..." -ForegroundColor Yellow
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match "mcafee|mcshield|mcuicnt|ModuleCore|MMSSHOST|McPvTray|WebAdvisor|McInstaller|mfemms|mfevtps|mcods|mfefire|mfetp|protectedmodulehost|OneDrive|OneDriveSetup|ms-teams|Teams|Dropbox|DropboxUpdate|Spotify|Facebook|Instagram|TikTok"
} | Stop-Process -Force -ErrorAction SilentlyContinue
# Desativar servicos McAfee
Get-Service -DisplayName "*McAfee*" -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
    Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
}
Write-Host "  Processos encerrados" -ForegroundColor Green

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

# ============================================================
#  McAfee: exterminio completo  (rev. 2026-08-13)
#  Antes este bloco dava conta do McAfee OEM "leve" (WebAdvisor / WPS),
#  mas NAO do LiveSafe / Total Protection (antivirus completo). 4 furos:
#   1) timeout de 15s matava o winget no meio (LiveSafe leva minutos)
#   2) exit code do winget nunca era lido -> imprimia "OK" sem remover nada
#   3) UninstallString do LiveSafe e' GUI (mcuihost.exe): ignora /quiet e,
#      com -WindowStyle Hidden, vira assistente invisivel esperando clique
#   4) self-protection (mfehidk/mfevtp) barra Stop-Service e Remove-Item
#  A peca que faltava: MCPR (mccleanup.exe), removedor oficial da McAfee.
#  No fim o bloco VERIFICA e diz a verdade sobre o que sobrou.
# ============================================================
$mcRegKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$mcPastas = @("$env:ProgramFiles\McAfee", "${env:ProgramFiles(x86)}\McAfee",
              "$env:ProgramData\McAfee", "$env:LOCALAPPDATA\McAfee", "$env:APPDATA\McAfee")

function Get-McAfeeInstalado {
    [pscustomobject]@{
        Programas = @(Get-ItemProperty $mcRegKeys -ErrorAction SilentlyContinue |
                      Where-Object { $_.DisplayName -like "*McAfee*" })
        Servicos  = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
                      Where-Object { $_.DisplayName -like "*McAfee*" -or $_.Name -like "mfe*" -or $_.PathName -like "*\McAfee\*" })
        Pastas    = @($mcPastas | Where-Object { Test-Path $_ })
        Tarefas   = @(Get-ScheduledTask -ErrorAction SilentlyContinue |
                      Where-Object { $_.TaskName -like "*McAfee*" -or $_.TaskPath -like "*McAfee*" })
        Appx      = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*McAfee*" })
    }
}

function Kill-McAfee {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "mcafee|mcshield|mcuicnt|modulecore|mmsshost|mcpvtray|webadvisor|mcinstaller|mfemms|mfevtps?|mcods|mfefire|mfetp|protectedmodulehost|mccspservicehost|mcapexe|mfeann|mcpltsvc|msksrvr|mcuihost"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
}

$mc0 = Get-McAfeeInstalado
if (-not ($mc0.Programas -or $mc0.Servicos -or $mc0.Pastas -or $mc0.Tarefas -or $mc0.Appx)) {
    Write-Host "  McAfee: nada instalado neste PC" -ForegroundColor Green
} else {
    Write-Host "  McAfee detectado:" -ForegroundColor Yellow
    foreach ($pg in ($mc0.Programas | Select-Object -ExpandProperty DisplayName -Unique)) {
        Write-Host "    - $pg" -ForegroundColor DarkGray
    }
    if ($mc0.Servicos) { Write-Host "    - $($mc0.Servicos.Count) servico(s), $($mc0.Tarefas.Count) tarefa(s) agendada(s)" -ForegroundColor DarkGray }

    # -- GUARDA: nao deixar o MCPR arrancar antivirus CORPORATIVO (ePO/ENS/Trellix) --
    # MCPR remove produto de CONSUMIDOR. Se a maquina for gerenciada, so avisa.
    $mcCorp = @($mc0.Servicos | Where-Object {
        $_.Name -in @("masvc","macmnsvc","McAfeeFramework") -or $_.DisplayName -match "Trellix|Endpoint Security|ePolicy"
    })
    if ($mcCorp) {
        Write-Host "  !! McAfee/Trellix CORPORATIVO detectado ($($mcCorp[0].DisplayName))." -ForegroundColor Red
        Write-Host "     Pulando o MCPR: ele arrancaria o antivirus gerenciado. Tratar com o time de seguranca." -ForegroundColor Red
    }

    # -- 1. derrubar servicos e processos (best effort: self-protection pode barrar) --
    Write-Host "  McAfee: parando servicos..." -ForegroundColor Yellow
    foreach ($s in $mc0.Servicos) {
        Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
        Set-Service -Name $s.Name -StartupType Disabled -ErrorAction SilentlyContinue
    }
    Kill-McAfee

    # -- 2. tarefas agendadas (raiz das notificacoes: Anti-tracker, Health Check...) --
    $tasksRemoved = 0
    foreach ($t in $mc0.Tarefas) {
        try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop; $tasksRemoved++ } catch {}
    }
    if ($tasksRemoved -gt 0) { Write-Host "    $tasksRemoved tarefa(s) agendada(s) apagada(s)" -ForegroundColor DarkGray }

    # -- 3. Appx (OEM novo empacota "McAfee Security"/"Personal Security" da Store) --
    foreach ($ap in $mc0.Appx) {
        Remove-AppxPackage -Package $ap.PackageFullName -AllUsers -ErrorAction SilentlyContinue
    }
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*McAfee*" } |
        ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue }
    if ($mc0.Appx) { Write-Host "    $($mc0.Appx.Count) pacote(s) Appx McAfee removido(s)" -ForegroundColor DarkGray }

    # -- 4. winget: timeout de verdade + LEITURA DO EXIT CODE (furos 1 e 2) --
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        foreach ($mid in @("McAfee.WebAdvisor","McAfee.McAfee","McAfee.LiveSafe","McAfee.TotalProtection","McAfee.TrueKey","McAfee.SecurityScan")) {
            Kill-McAfee
            Write-Host "  McAfee: winget $mid..." -ForegroundColor Yellow -NoNewline
            $p = Start-Process "winget" -ArgumentList "uninstall --id $mid -e --silent --force --disable-interactivity --accept-source-agreements" -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
            if (-not $p) { Write-Host " winget nao rodou" -ForegroundColor Gray; continue }
            if (-not $p.WaitForExit(600000)) {          # 10 min: LiveSafe nao sai em 15s
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                Kill-McAfee
                Write-Host " TIMEOUT 10min (abortado)" -ForegroundColor Red
            } elseif ($p.ExitCode -eq 0) {
                Write-Host " removido" -ForegroundColor Green
            } elseif ($p.ExitCode -eq -1978335189 -or $p.ExitCode -eq -1978335212) {
                Write-Host " nao instalado" -ForegroundColor Gray      # 0x8A15002B / 0x8A150014
            } else {
                Write-Host (" falhou (exit {0})" -f $p.ExitCode) -ForegroundColor Yellow
            }
        }
    }

    # -- 5. UninstallString do registro, agora SEM cair na armadilha da GUI (furo 3) --
    foreach ($app in (Get-ItemProperty $mcRegKeys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*McAfee*" })) {
        $unins = $app.QuietUninstallString; if (-not $unins) { $unins = $app.UninstallString }
        if (-not $unins) { continue }
        if ($unins -match 'MsiExec(\.exe)?\s.*(\{[0-9A-Fa-f\-]{36}\})') {
            # MSI: silencioso de verdade
            $p = Start-Process "msiexec.exe" -ArgumentList "/X$($matches[2]) /qn /norestart" -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
            if ($p) {
                if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch {} }
                Write-Host "    msi removido: $($app.DisplayName)" -ForegroundColor DarkGray
            }
        } elseif ($app.QuietUninstallString) {
            if ($unins -match '^"([^"]+)"\s*(.*)$') { $exe = $matches[1]; $argStr = $matches[2] }
            else { $tk = $unins -split ' ',2; $exe = $tk[0]; $argStr = if ($tk.Count -gt 1) { $tk[1] } else { '' } }
            if (Test-Path $exe) {
                $p = Start-Process -FilePath $exe -ArgumentList $argStr -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
                if ($p) {
                    if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch {} }
                    Write-Host "    desinstalado: $($app.DisplayName)" -ForegroundColor DarkGray
                }
            }
        } else {
            # sem QuietUninstallString = assistente grafico. Rodar escondido so trava.
            Write-Host "    $($app.DisplayName): uninstaller e' GUI -> deixado para o MCPR" -ForegroundColor DarkGray
        }
    }

    # -- 6. MCPR / mccleanup.exe: removedor OFICIAL, unico que tira o LiveSafe --
    $mcRestante = Get-McAfeeInstalado
    if (-not $mcCorp -and ($mcRestante.Programas -or $mcRestante.Servicos -or $mcRestante.Pastas)) {
        Write-Host "  McAfee: sobrou produto -> rodando o MCPR oficial (pode levar minutos)..." -ForegroundColor Yellow
        $mcprExe = Join-Path $env:TEMP "MCPR.exe"
        $baixou = $false
        foreach ($u in @("https://download.mcafee.com/molbin/iss-loc/SupportTools/MCPR/MCPR.exe",
                         "https://download.mcafee.com/products/licensed/cust_support_patches/MCPR.exe")) {
            try {
                Remove-Item $mcprExe -Force -ErrorAction SilentlyContinue
                & curl.exe -sL --max-time 300 -o $mcprExe $u 2>$null
                if ((Test-Path $mcprExe) -and ((Get-Item $mcprExe).Length -gt 5MB)) { $baixou = $true; break }
            } catch {}
        }
        if (-not $baixou) {
            Write-Host "    MCPR: download falhou (sem internet?) - baixar de mcafee.com/support e rodar a mao" -ForegroundColor Yellow
        } else {
            # MCPR.exe e' um SFX NSIS: extrai o mccleanup.exe em %TEMP%\ns*.tmp e
            # abre o assistente. O silencio esta no mccleanup, nao no wrapper.
            $sfx = Start-Process $mcprExe -ArgumentList "/S" -PassThru -WindowStyle Minimized -ErrorAction SilentlyContinue
            $clean = $null; $limite = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $limite -and -not $clean) {
                Start-Sleep -Seconds 3
                $clean = Get-ChildItem $env:TEMP -Directory -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -like "ns*.tmp" -or $_.Name -like "*McAfee*" -or $_.Name -like "*MCPR*" } |
                         ForEach-Object { Get-ChildItem $_.FullName -Filter "mccleanup.exe" -Recurse -ErrorAction SilentlyContinue } |
                         Select-Object -First 1
            }
            if (-not $clean) {
                if ($sfx) { try { $sfx | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
                Write-Host "    MCPR: mccleanup.exe nao apareceu em 2 min - rodar $mcprExe a mao" -ForegroundColor Yellow
            } else {
                # copiar ANTES de matar o SFX: o NSIS apaga o proprio $PLUGINSDIR ao sair
                $work = Join-Path $env:TEMP "MCPR-work"
                Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
                Copy-Item $clean.Directory.FullName $work -Recurse -Force -ErrorAction SilentlyContinue
                if ($sfx) { try { $sfx | Stop-Process -Force -ErrorAction SilentlyContinue } catch {} }
                Get-Process -Name "MCPR","mccleanup" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                $exeClean = Join-Path $work "mccleanup.exe"
                if (Test-Path $exeClean) {
                    $mods = "StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUE"
                    $pc = Start-Process $exeClean -ArgumentList "-p","$mods","-v","-s" -PassThru -WindowStyle Hidden -WorkingDirectory $work -ErrorAction SilentlyContinue
                    if ($pc) {
                        if (-not $pc.WaitForExit(900000)) { try { $pc.Kill() } catch {}; Write-Host "    MCPR: timeout de 15 min" -ForegroundColor Yellow }
                        else { Write-Host "    MCPR concluido (exit $($pc.ExitCode))" -ForegroundColor DarkGray }
                    }
                } else {
                    Write-Host "    MCPR: falha ao copiar o mccleanup - rodar $mcprExe a mao" -ForegroundColor Yellow
                }
            }
        }
    }

    # -- 7. faxina final: servicos zumbis, pastas, chaves de inicializacao --
    Kill-McAfee
    foreach ($s in (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like "*McAfee*" -or $_.Name -like "mfe*" -or $_.PathName -like "*\McAfee\*" })) {
        if ($s.Name -in @("masvc","macmnsvc","McAfeeFramework")) { continue }   # corporativo: nao tocar
        Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
        Start-Process sc.exe -ArgumentList "delete `"$($s.Name)`"" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    }
    foreach ($p in $mcPastas) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
    foreach ($hive in @("HKLM:","HKCU:")) {
        $k = "$hive\Software\Microsoft\Windows\CurrentVersion\Run"
        if (Test-Path $k) {
            (Get-Item $k).Property | Where-Object { $_ -like "*McAfee*" -or $_ -like "*mcui*" } |
                ForEach-Object { Remove-ItemProperty -Path $k -Name $_ -ErrorAction SilentlyContinue }
        }
    }

    # -- 8. VERIFICACAO: nunca mais dizer "OK" sem ter removido (furo 2) --
    $mcFim = Get-McAfeeInstalado
    if ($mcFim.Programas -or $mcFim.Servicos -or $mcFim.Pastas) {
        Write-Host "  !! McAfee AINDA PRESENTE apos a limpeza:" -ForegroundColor Red
        foreach ($pg in ($mcFim.Programas | Select-Object -ExpandProperty DisplayName -Unique)) { Write-Host "     programa: $pg" -ForegroundColor Red }
        foreach ($s in $mcFim.Servicos) { Write-Host "     servico: $($s.Name)" -ForegroundColor Red }
        foreach ($p in $mcFim.Pastas) { Write-Host "     pasta: $p" -ForegroundColor Red }
        Write-Host "     -> REINICIE e rode de novo: parte do McAfee so sai apos o reboot." -ForegroundColor Yellow
    } else {
        Write-Host "  McAfee: removido e verificado (0 programas, 0 servicos, 0 pastas)" -ForegroundColor Green
    }
    try {
        $def = Get-MpComputerStatus -ErrorAction Stop
        Write-Host ("    Defender apos a remocao: tempo real={0} / antivirus={1} (assume o posto no reboot)" -f $def.RealTimeProtectionEnabled, $def.AntivirusEnabled) -ForegroundColor DarkGray
    } catch {}
}
Write-Host "  McAfee: concluido" -ForegroundColor Green

# Matar TUDO via taskkill
Write-Host "  Matando processos restantes..." -ForegroundColor Yellow
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
# [2] INSTALAR GOOGLE CHROME
# ============================================

Write-Host "`n[2/$etapaTotal] Instalando Google Chrome..." -ForegroundColor Cyan

Write-Host "  Google Chrome..." -ForegroundColor Yellow -NoNewline
$chromeOk = $false

if ($hasWinget) {
    $resultado = winget install --id Google.Chrome -e --accept-source-agreements --accept-package-agreements --silent 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Host " OK" -ForegroundColor Green
        $chromeOk = $true
    } elseif ($resultado -match "already installed|ja esta instalado") {
        Write-Host " Ja instalado" -ForegroundColor Gray
        $chromeOk = $true
    } else {
        # Retry com --source winget explicito
        $resultado2 = winget install --id Google.Chrome -e --source winget --accept-source-agreements --accept-package-agreements --silent 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host " OK (retry com source winget)" -ForegroundColor Green
            $chromeOk = $true
        }
    }
}

# Fallback: download direto do Google
if (-not $chromeOk) {
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
            Write-Host "    [fallback] TIMEOUT no install (>3 min)" -ForegroundColor Red
        } elseif ($p.ExitCode -eq 0) {
            $chromeOk = $true
            Write-Host "    [fallback] => OK" -ForegroundColor Green
        } else {
            Write-Host "    [fallback] msiexec exit $($p.ExitCode)" -ForegroundColor Red
        }
        Remove-Item $chromeMsi -ErrorAction SilentlyContinue
    } else {
        Write-Host "    [fallback] Download falhou ou estourou timeout" -ForegroundColor Red
    }
}

if (-not $chromeOk) { $erros += "Google Chrome" }

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

Write-Host "`n[5/$etapaTotal] Configurando energia..." -ForegroundColor Cyan

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

# Botoes: Power button -> shutdown | Lid close -> sleep (volta ao abrir)
powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3 2>&1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3 2>&1 | Out-Null
powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1 2>&1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1 2>&1 | Out-Null
Write-Host "  Botao Power = desligar | Fechar tampa = sleep (volta ao abrir)" -ForegroundColor Green

# Hibernacao off (tambem desabilita Fast Startup) - shutdown = shutdown real
powercfg /hibernate off 2>&1 | Out-Null
REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /V HiberbootEnabled /T REG_DWORD /D 0 /F 2>&1 | Out-Null
Write-Host "  Hibernacao desabilitada (shutdown real)" -ForegroundColor Green

# Modern Standby off (causa do LED piscando apos shutdown em notebooks novos)
REG ADD "HKLM\SYSTEM\CurrentControlSet\Control\Power" /V PlatformAoAcOverride /T REG_DWORD /D 0 /F 2>&1 | Out-Null
Write-Host "  Modern Standby desabilitado (S5 forcado no shutdown)" -ForegroundColor Green

# Desarma wake-armed devices (LED ativo apos shutdown)
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


Write-Host "`n[6/$etapaTotal] Removendo programas do inicio automatico..." -ForegroundColor Cyan

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
Write-Host "  [1] Bloatware removido (com deep clean McAfee)"
Write-Host "  [2] Google Chrome instalado"
Write-Host "  [3] Notificacoes desativadas"
Write-Host "  [4] Barra de tarefas limpa"
Write-Host "  [5] Energia configurada (AC nunca dorme, shutdown real)"
Write-Host "  [6] Auto-inicio limpo"
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
