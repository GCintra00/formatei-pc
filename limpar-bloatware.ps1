# ============================================
# LIMPAR BLOATWARE - so a faxina, sem instalar nada
# Apps da Microsoft que vem de fabrica + McAfee + lixo de terceiros
# (jogos, streaming, redes sociais) + OneDrive/Teams pessoal.
# NAO mexe em: Store, App Installer (winget), Calculadora, Fotos, Camera,
# Bloco de Notas, Paint, Ferramenta de Captura, Media Player, Assistencia
# Rapida, Terminal, Edge, Office instalado, ferramentas do fabricante
# (Lenovo Vantage, HP, Dell) - elas controlam camera/bateria/teclado.
# Compativel com Windows 10 e 11
# ============================================

$URL = 'https://raw.githubusercontent.com/GCintra00/formatei-pc/master/limpar-bloatware.ps1'

# ---- auto-elevacao (re-baixa a si mesmo elevado, sem arquivo) ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Elevando para Administrador...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',"irm $URL | iex"
    return
}

$Host.UI.RawUI.WindowTitle = 'Limpar bloatware - nao feche esta janela'

# Manter PC acordado (o McAfee LiveSafe leva minutos para sair)
try {
    $sig = '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    $sleepHelper = Add-Type -MemberDefinition $sig -Name "SleepLB" -Namespace "Win32" -PassThru -ErrorAction SilentlyContinue
    if ($sleepHelper) { $sleepHelper::SetThreadExecutionState(0x80000003) | Out-Null }
} catch {}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$lbDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'UTI-backup'
New-Item -ItemType Directory -Path $lbDir -Force -ErrorAction SilentlyContinue | Out-Null
$logPath = Join-Path $lbDir ("limpar-bloatware-log_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
try { Start-Transcript -Path $logPath -Force -ErrorAction Stop | Out-Null; $logAtivo = $true } catch { $logAtivo = $false }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  LIMPAR BLOATWARE (Microsoft + McAfee)" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') | $env:COMPUTERNAME | $env:USERNAME" -ForegroundColor DarkGray
try { $os = Get-CimInstance Win32_OperatingSystem; Write-Host "  $($os.Caption) (build $($os.BuildNumber))" -ForegroundColor DarkGray } catch {}
if ($logAtivo) { Write-Host "  Log: $logPath" -ForegroundColor DarkGray }
Write-Host "========================================" -ForegroundColor Cyan

# Contador de uso
try { Invoke-RestMethod -Uri "https://script.google.com/macros/s/AKfycbxCNI2nrcb-mDEMrSi9cmFfrvPBOT3T3MmwnnmNfWnbisdUqZDay59-eok7tg9p9varRg/exec?script=limpar-bloatware" -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null } catch {}

$etapaTotal = 4
$removidos = @()
$falhas = @()
$hasWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)

# ============================================
# [1] APPS DA MICROSOFT E DE TERCEIROS (Appx)
# ============================================
Write-Host "`n[1/$etapaTotal] Removendo apps de fabrica (Microsoft e terceiros)..." -ForegroundColor Cyan

$bloatware = @(
    # --- Microsoft ---
    "Microsoft.549981C3F5F10",                 # Cortana
    "Microsoft.Copilot*",
    "Microsoft.Windows.Ai.Copilot.Provider*",
    "Microsoft.BingNews*",
    "Microsoft.BingWeather*",
    "Microsoft.BingSearch*",
    "Microsoft.BingFinance*",
    "Microsoft.BingSports*",
    "Microsoft.News*",
    "Microsoft.GetHelp*",
    "Microsoft.Getstarted*",                   # Dicas
    "Microsoft.MicrosoftOfficeHub*",           # "Microsoft 365 (Office)" propaganda - NAO e o Office instalado
    "Microsoft.Office.OneNote*",               # OneNote da Store (Win10)
    "Microsoft.OutlookForWindows*",            # Outlook (novo)
    "Microsoft.WindowsMail*",
    "Microsoft.windowscommunicationsapps*",    # Email e Calendario (Win10)
    "Microsoft.People*",
    "Microsoft.SkypeApp*",
    "Microsoft.Messaging*",
    "Microsoft.OneConnect*",
    "Microsoft.Wallet*",
    "Microsoft.Todos*",
    "Microsoft.PowerAutomateDesktop*",
    "Microsoft.MicrosoftSolitaireCollection*",
    "Microsoft.Microsoft3DViewer*",
    "Microsoft.MSPaint",                       # Paint 3D (Win10). O Paint normal e Microsoft.Paint
    "Microsoft.Print3D*",
    "Microsoft.MixedReality.Portal*",
    "Microsoft.WindowsFeedbackHub*",
    "Microsoft.WindowsMaps*",
    "Microsoft.ZuneVideo*",                    # Filmes e TV (ZuneMusic = Media Player, fica)
    "Microsoft.YourPhone*",                    # Vincular ao Celular
    "MicrosoftWindows.CrossDevice*",
    "Microsoft.Windows.DevHome*",
    "MicrosoftCorporationII.MicrosoftFamily*",
    "Microsoft.Clipchamp*",
    "Clipchamp*",
    "Microsoft.MicrosoftTeams*",
    "MicrosoftTeams*",
    "MSTeams*",
    "Microsoft.Teams*",
    "Microsoft.OneDrive*",
    "Microsoft.GamingApp*",
    "Microsoft.XboxApp*",
    "Microsoft.XboxGameOverlay*",
    "Microsoft.XboxGamingOverlay*",
    "Microsoft.XboxSpeechToTextOverlay*",
    "Microsoft.XboxIdentityProvider*",
    "Microsoft.Xbox.TCUI*",
    "Microsoft.LinkedIn*",
    "7EE7776C.LinkedInforWindows*",
    # --- McAfee empacotado da Store (OEM novo) ---
    "McAfee*",
    "*McAfeeSecurity*",
    # --- terceiros que vem "patrocinados" ---
    "SpotifyAB.SpotifyMusic*",
    "king.com.*",
    "BytedancePte.Ltd.TikTok*",
    "Facebook*",
    "Instagram*",
    "*.Twitter*",
    "*Netflix*",
    "AmazonVideo.PrimeVideo*",
    "Disney*",
    "*.AdobePhotoshopExpress*",
    "*.Duolingo*",
    "*CaesarsSlotsFreeCasino*",
    "*MarchofEmpires*",
    "*HiddenCity*",
    "*FarmVille*",
    "*BubbleWitch*",
    "*Royal Revolt*",
    "*Asphalt*",
    "*PicsArt*",
    "*.Flipboard*",
    "*.TuneInRadio*",
    "*.Plex*",
    "*.EclipseManager*",
    "*.ActiproSoftware*",
    "*.Booking*",
    "Dropbox*"
)

foreach ($app in $bloatware) {
    # 1. instalado em algum perfil
    $pacotes = @(Get-AppxPackage -AllUsers -Name $app -ErrorAction SilentlyContinue)
    foreach ($pacote in $pacotes) {
        try {
            Remove-AppxPackage -Package $pacote.PackageFullName -AllUsers -ErrorAction Stop
            if ($removidos -notcontains $pacote.Name) { $removidos += $pacote.Name }
            Write-Host "  Removido: $($pacote.Name)" -ForegroundColor Green
        } catch {
            # -AllUsers falha em alguns builds de Win10: tenta so no perfil atual
            try {
                Remove-AppxPackage -Package $pacote.PackageFullName -ErrorAction Stop
                if ($removidos -notcontains $pacote.Name) { $removidos += $pacote.Name }
                Write-Host "  Removido (perfil atual): $($pacote.Name)" -ForegroundColor Green
            } catch {
                if ($falhas -notcontains $pacote.Name) { $falhas += $pacote.Name }
                Write-Host "  Nao saiu: $($pacote.Name)" -ForegroundColor Yellow
            }
        }
    }
    # 2. provisionado (senao volta em todo usuario NOVO que logar)
    Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $app } |
        ForEach-Object {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                Write-Host "  Desprovisionado: $($_.DisplayName)" -ForegroundColor DarkGray
                if ($removidos -notcontains $_.DisplayName) { $removidos += $_.DisplayName }
            } catch {}
        }
}
if ($removidos.Count -eq 0) { Write-Host "  Nenhum app de fabrica encontrado" -ForegroundColor Gray }

# ============================================
# [2] McAFEE (o maldito)
# ============================================
Write-Host "`n[2/$etapaTotal] McAfee..." -ForegroundColor Cyan

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

# ============================================
# [3] ONEDRIVE, TEAMS PESSOAL, DROPBOX (Win32)
# ============================================
Write-Host "`n[3/$etapaTotal] OneDrive, Teams e Dropbox..." -ForegroundColor Cyan

foreach ($nome in @("OneDrive","OneDriveSetup","ms-teams","Teams","Dropbox","DropboxUpdate")) {
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
# tira o icone do Explorer e impede de reinstalar sozinho
try {
    $k = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    Set-ItemProperty -Path $k -Name "DisableFileSyncNGSC" -Value 1 -Type DWord -ErrorAction SilentlyContinue
} catch {}
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

# ============================================
# [4] IMPEDIR QUE VOLTEM
# O Windows reinstala Candy Crush & cia sozinho ("apps sugeridos").
# ============================================
Write-Host "`n[4/$etapaTotal] Impedindo que o lixo volte sozinho..." -ForegroundColor Cyan
try {
    $cdm = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    if (-not (Test-Path $cdm)) { New-Item -Path $cdm -Force | Out-Null }
    foreach ($v in @("SilentInstalledAppsEnabled","PreInstalledAppsEnabled","PreInstalledAppsEverEnabled",
                     "OemPreInstalledAppsEnabled","ContentDeliveryAllowed","FeatureManagementEnabled",
                     "SoftLandingEnabled","SystemPaneSuggestionsEnabled",
                     "SubscribedContent-338388Enabled","SubscribedContent-338389Enabled",
                     "SubscribedContent-310093Enabled","SubscribedContent-353694Enabled",
                     "SubscribedContent-353696Enabled")) {
        Set-ItemProperty -Path $cdm -Name $v -Value 0 -Type DWord -ErrorAction SilentlyContinue
    }
    $cc = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    if (-not (Test-Path $cc)) { New-Item -Path $cc -Force | Out-Null }
    Set-ItemProperty -Path $cc -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $cc -Name "DisableSoftLanding" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Write-Host "  Apps sugeridos e reinstalacao automatica: desligados" -ForegroundColor Green
} catch {
    Write-Host "  ERRO: $($_.Exception.Message)" -ForegroundColor Red
}

# ============================================
# RESUMO
# ============================================
$mcFinal = Get-McAfeeInstalado
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  RESUMO" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ("  Removidos: {0}" -f $removidos.Count) -ForegroundColor Green
foreach ($r in ($removidos | Sort-Object -Unique)) { Write-Host "    - $r" -ForegroundColor DarkGray }
if ($falhas.Count -gt 0) {
    Write-Host ("  Nao sairam: {0} (geralmente saem apos reiniciar e rodar de novo)" -f $falhas.Count) -ForegroundColor Yellow
    foreach ($f in $falhas) { Write-Host "    - $f" -ForegroundColor Yellow }
}
if ($mcFinal.Programas -or $mcFinal.Servicos -or $mcFinal.Pastas) {
    Write-Host "  McAfee: AINDA PRESENTE -> REINICIE e rode esta ferramenta de novo" -ForegroundColor Red
} else {
    Write-Host "  McAfee: nenhum vestigio" -ForegroundColor Green
}
Write-Host "  Recomendado: reiniciar o PC." -ForegroundColor Cyan
if ($logAtivo) { Write-Host "  Log: $logPath" -ForegroundColor DarkGray; try { Stop-Transcript | Out-Null } catch {} }
Write-Host ""
Read-Host "Enter para fechar"
