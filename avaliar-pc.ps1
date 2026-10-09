# ============================================================================
# AVALIAR PC - checklist de entrega / antes do estoque   (IG Networks / TI)
# ----------------------------------------------------------------------------
# Para quando um PC vai ser GUARDADO no estoque ou ENTREGUE a outra pessoa:
# passa um pente por bateria, carga/lentidao, temperatura, camera, som,
# dispositivos (teclado/mouse/touchpad) e rede, e diz num relampago se esta
# PRONTO ou se tem algo a olhar.
#
# DOIS resultados:
#   1) UMA JANELA com um semaforo por item (verde = ok, amarelo = atencao,
#      vermelho = problema, cinza = nao se aplica). SO as luzes, sem numeros.
#   2) UMA PASTA no Desktop com o relatorio COMPLETO (todos os numeros) +
#      um bloco pronto pra colar numa IA interpretar. Desktop\UTI-backup\
#      Avaliacao-<PC>-<data>\
#
# Camera e som sao testados DE VERDADE: o script abre a camera e toca um som,
# e VOCE confirma se viu/ouviu. So detectar o driver nao prova que sai imagem.
#
# NAO altera nada no PC. E' so leitura + um teste de carga (burn-in) na CPU.
# Com ADMIN ve a saude real da bateria; sem admin roda mesmo assim (parcial).
#
# Uso:  irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/avaliar-pc.ps1 | iex
#   burn-in mais curto p/ testar:  $env:AVP_SEGUNDOS = '20'  antes de rodar
# ============================================================================
$ErrorActionPreference = 'SilentlyContinue'

function Safe($b) { try { & $b } catch { $null } }

$SEG_CARGA = 180
if ($env:AVP_SEGUNDOS -match '^\d+$') { $SEG_CARGA = [int]$env:AVP_SEGUNDOS }

$EH_ADMIN = $false
Safe { $EH_ADMIN = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

$HOST_NOME = $env:COMPUTERNAME
$USUARIO   = $env:USERNAME
$AGORA     = Get-Date
$CARIMBO   = $AGORA.ToString('yyyy-MM-dd_HHmm')

# ---- pasta de saida: Desktop\UTI-backup\Avaliacao-<PC>-<data> ----
$desk = Safe { [Environment]::GetFolderPath('Desktop') }
if (-not $desk -or -not (Test-Path $desk)) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
$baseBk = Join-Path $desk 'UTI-backup'
Safe { if (-not (Test-Path $baseBk)) { New-Item -ItemType Directory -Path $baseBk -Force | Out-Null } }
$PASTA = Join-Path $baseBk ("Avaliacao-{0}-{1}" -f $HOST_NOME, $CARIMBO)
Safe { if (-not (Test-Path $PASTA)) { New-Item -ItemType Directory -Path $PASTA -Force | Out-Null } }
if (-not (Test-Path $PASTA)) { $PASTA = $baseBk }

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  AVALIAR PC - $HOST_NOME" -ForegroundColor Cyan
Write-Host "  Relatorio sera salvo em: $PASTA" -ForegroundColor Gray
if (-not $EH_ADMIN) { Write-Host "  (sem admin: a saude da bateria pode nao aparecer)" -ForegroundColor DarkYellow }
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""

# Cada teste devolve: @{Nome; Luz('verde'/'amarelo'/'vermelho'/'cinza'); Resumo; Linhas=@()}
$RES = [System.Collections.Generic.List[object]]::new()
function Passo($txt) { Write-Host "  -> $txt" -ForegroundColor White }

# ===================== 1. BATERIA =====================
function Test-Bateria {
    $o = @{ Nome='Bateria'; Luz='cinza'; Resumo='nao avaliada'; Linhas=@() }
    $bat = Safe { Get-CimInstance Win32_Battery -ErrorAction Stop }
    if (-not $bat) { $o.Luz='cinza'; $o.Resumo='sem bateria (desktop?)'; $o.Linhas += 'Nenhuma bateria detectada - provavelmente um desktop.'; return $o }

    $o.Linhas += "Carga atual: $($bat.EstimatedChargeRemaining)%"
    $o.Linhas += "Estado: $(if($bat.BatteryStatus -eq 2){'no carregador'}else{'na bateria'})"

    # relatorio oficial do Windows - HTML (humano) + XML (p/ eu ler a capacidade).
    # Estar no carregador NAO atrapalha: capacidade de fabrica/atual sao valores fixos.
    # Ambos costumam exigir admin.
    $html = Join-Path $PASTA 'bateria-relatorio.html'
    $xml  = Join-Path $PASTA 'bateria.xml'
    Safe { powercfg /batteryreport /output "$html" | Out-Null }
    Safe { powercfg /batteryreport /output "$xml" /XML | Out-Null }

    # 1a fonte: WMI (root\wmi). 2a fonte (fallback): o XML do powercfg.
    $design = Safe { [double](Get-CimInstance -Namespace root\wmi -Class BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity }
    $full   = Safe { [double](Get-CimInstance -Namespace root\wmi -Class BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity }
    $ciclos = Safe { [int](Get-CimInstance -Namespace root\wmi -Class BatteryCycleCount -ErrorAction Stop | Select-Object -First 1).CycleCount }
    $fonte = 'WMI'
    if ((-not $design -or -not $full -or $design -le 0) -and (Test-Path $xml)) {
        $raw = Safe { Get-Content $xml -Raw }
        if ($raw) {
            $md = [regex]::Match($raw, '<DesignCapacity>(\d+)</DesignCapacity>')
            $mf = [regex]::Match($raw, '<FullChargeCapacity>(\d+)</FullChargeCapacity>')
            $mc = [regex]::Match($raw, '<CycleCount>(\d+)</CycleCount>')
            if ($md.Success) { $design = [double]$md.Groups[1].Value }
            if ($mf.Success) { $full   = [double]$mf.Groups[1].Value }
            if ($mc.Success -and -not $ciclos) { $ciclos = [int]$mc.Groups[1].Value }
            $fonte = 'relatorio Windows'
        }
    }

    if ($design -and $full -and $design -gt 0) {
        $saude = [math]::Round(($full / $design) * 100)
        $o.Linhas += "Capacidade de fabrica: $([int]$design) mWh"
        $o.Linhas += "Capacidade atual     : $([int]$full) mWh"
        $o.Linhas += "Saude da bateria     : $saude% da original (fonte: $fonte)"
        if ($ciclos) { $o.Linhas += "Ciclos de carga      : $ciclos" }
        if     ($saude -ge 80) { $o.Luz='verde';    $o.Resumo="saude $saude% - boa" }
        elseif ($saude -ge 50) { $o.Luz='amarelo';  $o.Resumo="saude $saude% - desgastada" }
        else                   { $o.Luz='vermelho'; $o.Resumo="saude $saude% - trocar" }
    } else {
        if (-not $EH_ADMIN) { $o.Luz='cinza'; $o.Resumo='saude exige admin'; $o.Linhas += 'Rode como ADMINISTRADOR para ver a saude real (pelo canivete ja vem elevado).' }
        else { $o.Luz='amarelo'; $o.Resumo='saude indisponivel'; $o.Linhas += 'Nem o WMI nem o relatorio do Windows expuseram a capacidade - veja o HTML.' }
    }
    if (Test-Path $html) { $o.Linhas += "Relatorio HTML da bateria: $html" }
    return $o
}

# ===================== 2. CARGA / LENTIDAO (burn-in) =====================
function Get-ClockPerf {
    $p = Safe { Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop | Where-Object Name -eq '_Total' }
    if ($p) { return [double]$p.PercentProcessorPerformance }
    $c = Safe { (Get-Counter '\Processor Information(_Total)\% of Maximum Frequency' -ErrorAction Stop).CounterSamples[0].CookedValue }
    if ($c) { return [double]$c }
    return -1
}
function Get-TempC {
    $t = Safe { Get-CimInstance -Namespace root\wmi -Class MSAcpi_ThermalZoneTemperature -ErrorAction Stop }
    if ($t) {
        $maxK = ($t | ForEach-Object { $_.CurrentTemperature } | Measure-Object -Maximum).Maximum
        if ($maxK -gt 0) { return [math]::Round(($maxK / 10) - 273.15, 1) }
    }
    return $null
}
function Test-Carga {
    $o = @{ Nome='Processador / lentidao'; Luz='cinza'; Resumo=''; Linhas=@() }
    $cpu = Safe { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 }
    if ($cpu) { $o.Linhas += "CPU: $($cpu.Name.Trim())" ; $o.Linhas += "Clock nominal: $([math]::Round($cpu.MaxClockSpeed/1000,2)) GHz" }

    $idle = Get-ClockPerf
    $tempInicio = Get-TempC
    $o.Linhas += ("Clock em repouso: {0}% do nominal" -f ([math]::Round($idle)))
    if ($tempInicio -ne $null) { $o.Linhas += "Temperatura em repouso: $tempInicio C" }

    $n = [int]$env:NUMBER_OF_PROCESSORS; if ($n -lt 1) { $n = 2 }
    Passo ("Teste de carga em $n nucleos por $SEG_CARGA s (burn-in)...")
    $jobs = @()
    for ($i=0; $i -lt $n; $i++) {
        $jobs += Start-Job -ScriptBlock { param($s) $fim=(Get-Date).AddSeconds($s); $x=1.0; while((Get-Date) -lt $fim){ $x=[math]::Sqrt($x+1.234567) } } -ArgumentList ($SEG_CARGA + 3)
    }
    Start-Sleep -Seconds 3
    $picoPerf = 0.0; $picoTemp = $tempInicio
    for ($s=1; $s -le $SEG_CARGA; $s++) {
        $pf = Get-ClockPerf; if ($pf -gt $picoPerf) { $picoPerf = $pf }
        $tc = Get-TempC; if ($tc -ne $null -and ($picoTemp -eq $null -or $tc -gt $picoTemp)) { $picoTemp = $tc }
        if ($s % 5 -eq 0 -or $s -eq $SEG_CARGA) {
            $tstr = if ($picoTemp -ne $null) { ", pico $picoTemp C" } else { '' }
            Write-Progress -Activity "Burn-in da CPU" -Status ("{0}/{1}s  pico {2}% do nominal{3}" -f $s,$SEG_CARGA,[math]::Round($picoPerf),$tstr) -PercentComplete ([int]($s*100/$SEG_CARGA))
        }
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity "Burn-in da CPU" -Completed
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue

    $o.Linhas += ("Pico de clock sob carga: {0}% do nominal" -f ([math]::Round($picoPerf)))
    if ($picoTemp -ne $null) { $o.Linhas += "Pico de temperatura sob carga: $picoTemp C" }

    # erros de hardware WHEA durante a ultima hora (so admin le o log System com detalhe)
    $whea = Safe { (Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$AGORA.AddHours(-1) } -ErrorAction Stop | Measure-Object).Count }
    if ($whea -and $whea -gt 0) { $o.Linhas += "ERROS DE HARDWARE (WHEA) na ultima hora: $whea" }

    # veredito
    if ($picoPerf -lt 0) { $o.Luz='cinza'; $o.Resumo='nao foi possivel medir o clock' }
    elseif ($whea -and $whea -gt 0) { $o.Luz='vermelho'; $o.Resumo='erro de hardware (WHEA) no teste' }
    elseif ($picoPerf -ge 90) { $o.Luz='verde';   $o.Resumo='clock segura sob carga' }
    elseif ($picoPerf -ge 70) { $o.Luz='amarelo'; $o.Resumo='clock cai sob carga (throttling leve)' }
    else                      { $o.Luz='vermelho';$o.Resumo='CPU freada sob carga' }
    if ($picoTemp -ne $null -and $picoTemp -ge 90 -and $o.Luz -ne 'vermelho') { $o.Luz='amarelo'; $o.Resumo += " / quente ($picoTemp C)" }
    return $o
}

# ===================== 3. CAMERA (interativo) =====================
function Test-Camera {
    $o = @{ Nome='Camera'; Luz='cinza'; Resumo=''; Linhas=@() }
    $cams = Safe { Get-PnpDevice -Class Camera,Image -ErrorAction Stop | Where-Object { $_.Name -and $_.Name -notmatch 'Virtual|OBS|Snap' } }
    if (-not $cams) { $o.Luz='vermelho'; $o.Resumo='nenhuma camera encontrada'; $o.Linhas += 'O Windows nao lista nenhuma camera fisica.'; return $o }
    foreach ($c in $cams) { $o.Linhas += ("Camera: {0} [{1}]" -f $c.Name, $c.Status) }
    $comErro = $cams | Where-Object { $_.Status -ne 'OK' }
    if ($comErro) { $o.Luz='vermelho'; $o.Resumo='camera com erro de driver'; return $o }

    Passo 'Abrindo a camera - OLHE A TELA (vai pedir confirmacao)...'
    Safe { Start-Process 'microsoft.windows.camera:' }
    Start-Sleep -Seconds 2
    $r = [System.Windows.Forms.MessageBox]::Show("A camera abriu e voce esta VENDO a imagem na tela?`n`nSim = funciona   Nao = nao abriu / tela preta", 'Teste de camera', 'YesNo', 'Question')
    Safe { Get-Process WindowsCamera -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null } }
    if ($r -eq 'Yes') { $o.Luz='verde'; $o.Resumo='imagem confirmada'; $o.Linhas += 'Operador CONFIRMOU que viu a imagem.' }
    else { $o.Luz='vermelho'; $o.Resumo='sem imagem (confirmado)'; $o.Linhas += 'Operador NAO viu imagem - driver presente mas sem saida de video.' }
    return $o
}

# ===================== 4. SOM (interativo) =====================
function Test-Som {
    $o = @{ Nome='Som'; Luz='cinza'; Resumo=''; Linhas=@() }
    $snd = Safe { Get-PnpDevice -Class AudioEndpoint,MEDIA -ErrorAction Stop | Where-Object { $_.Status -eq 'OK' -and $_.Name } }
    if (-not $snd) { $o.Luz='vermelho'; $o.Resumo='nenhuma saida de audio'; $o.Linhas += 'Nenhum dispositivo de audio OK encontrado.'; return $o }
    foreach ($d in ($snd | Select-Object -First 6)) { $o.Linhas += ("Audio: {0} [{1}]" -f $d.Name, $d.Status) }

    Passo 'Tocando um som de teste - ESCUTE (vai pedir confirmacao)...'
    $tocou = $false
    foreach ($wav in @("$env:WINDIR\Media\Alarm01.wav","$env:WINDIR\Media\notify.wav","$env:WINDIR\Media\tada.wav")) {
        if (Test-Path $wav) { Safe { (New-Object System.Media.SoundPlayer $wav).PlaySync(); $tocou = $true } ; if ($tocou) { break } }
    }
    if (-not $tocou) { Safe { [System.Media.SystemSounds]::Exclamation.Play(); Start-Sleep -Milliseconds 800; [System.Media.SystemSounds]::Exclamation.Play() } }
    $r = [System.Windows.Forms.MessageBox]::Show("Voce OUVIU o som de teste pelos alto-falantes?`n`nSim = funciona   Nao = nao saiu som", 'Teste de som', 'YesNo', 'Question')
    if ($r -eq 'Yes') { $o.Luz='verde'; $o.Resumo='som confirmado'; $o.Linhas += 'Operador CONFIRMOU que ouviu o som.' }
    else { $o.Luz='vermelho'; $o.Resumo='sem som (confirmado)'; $o.Linhas += 'Operador NAO ouviu - checar alto-falante / dispositivo padrao / volume.' }
    return $o
}

# ===================== 5. DISPOSITIVOS (teclado/mouse/touchpad/etc) =====================
function Test-Dispositivos {
    $o = @{ Nome='Teclado e dispositivos'; Luz='cinza'; Resumo=''; Linhas=@() }
    $todos = Safe { Get-PnpDevice -PresentOnly -ErrorAction Stop }
    if (-not $todos) { $o.Luz='cinza'; $o.Resumo='nao foi possivel listar'; return $o }

    $comErro = $todos | Where-Object { $_.Status -eq 'ERROR' -or ($_.Status -eq 'UNKNOWN') }
    foreach ($cls in @('Keyboard','Mouse','HIDClass')) {
        $d = $todos | Where-Object { $_.Class -eq $cls }
        if ($d) { $o.Linhas += ("{0}: {1} dispositivo(s), {2} com erro" -f $cls, @($d).Count, @($d | Where-Object Status -ne 'OK').Count) }
        else    { $o.Linhas += "${cls}: nenhum presente" }
    }
    $temTeclado = ($todos | Where-Object { $_.Class -eq 'Keyboard' -and $_.Status -eq 'OK' })
    $temPonteiro = ($todos | Where-Object { $_.Class -in 'Mouse','HIDClass' -and $_.Status -eq 'OK' })

    if ($comErro) {
        $o.Linhas += ''
        $o.Linhas += 'Dispositivos com problema:'
        foreach ($e in $comErro) { $o.Linhas += ("  [{0}] {1} ({2})" -f $e.Status, $e.Name, $e.Class) }
    }

    if (-not $temTeclado -or -not $temPonteiro) { $o.Luz='vermelho'; $o.Resumo='teclado ou mouse/touchpad faltando' }
    elseif ($comErro) {
        $critico = $comErro | Where-Object { $_.Class -in 'Keyboard','Mouse','HIDClass','Net','Bluetooth','Media' }
        if ($critico) { $o.Luz='vermelho'; $o.Resumo=("{0} dispositivo(s) importantes com erro" -f $critico.Count) }
        else          { $o.Luz='amarelo';  $o.Resumo=("{0} dispositivo(s) sem driver" -f $comErro.Count) }
    }
    else { $o.Luz='verde'; $o.Resumo='tudo conectado, sem erros' }
    return $o
}

# ===================== 6. REDE =====================
function Test-Rede {
    $o = @{ Nome='Rede'; Luz='cinza'; Resumo=''; Linhas=@() }
    $up = Safe { Get-NetAdapter -Physical -ErrorAction Stop | Where-Object Status -eq 'Up' }
    if (-not $up) { $o.Luz='vermelho'; $o.Resumo='nenhuma placa conectada'; $o.Linhas += 'Nenhuma placa de rede fisica esta UP.'; return $o }
    foreach ($a in $up) { $o.Linhas += ("Placa UP: {0} ({1})" -f $a.Name, $a.LinkSpeed) }

    # sinal WiFi, se houver
    $wifi = Safe { (netsh wlan show interfaces) 2>$null }
    if ($wifi) {
        $sig = ($wifi | Select-String 'Signal|Sinal|Senal' | Select-Object -First 1)
        if ($sig) { $o.Linhas += ("WiFi " + ($sig.ToString().Trim())) }
    }

    $gw = Safe { (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop }
    $okGw = $false; $okNet = $false
    if ($gw) { $okGw = Safe { Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction Stop } ; $o.Linhas += "Ping no roteador ($gw): $(if($okGw){'OK'}else{'FALHOU'})" }
    $okNet = Safe { Test-Connection -ComputerName '8.8.8.8' -Count 2 -Quiet -ErrorAction Stop } ; $o.Linhas += "Ping na internet (8.8.8.8): $(if($okNet){'OK'}else{'FALHOU'})"

    # velocidade REAL de download (ve se a placa/link puxa bem, nao so se "chega")
    $mbps = $null
    if ($okNet) {
        Passo 'Medindo velocidade de download...'
        $url = 'https://speed.cloudflare.com/__down?bytes=10000000'   # 10 MB
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            $tmp = Join-Path $env:TEMP 'avp-speed.tmp'
            Invoke-WebRequest -Uri $url -OutFile $tmp -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
            $sw.Stop(); $ProgressPreference = $old
            $bytes = (Get-Item $tmp).Length
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            if ($sw.Elapsed.TotalSeconds -gt 0 -and $bytes -gt 0) {
                $mbps = [math]::Round(($bytes * 8) / $sw.Elapsed.TotalSeconds / 1MB, 1)
                $o.Linhas += "Velocidade de download: $mbps Mbps (baixou $([math]::Round($bytes/1MB)) MB em $([math]::Round($sw.Elapsed.TotalSeconds,1))s)"
            }
        } catch { $o.Linhas += "Velocidade de download: nao medida ($($_.Exception.Message))" }
    }

    if ($okNet) {
        if     ($mbps -ne $null -and $mbps -lt 5) { $o.Luz='amarelo'; $o.Resumo="internet ok, mas lenta ($mbps Mbps)" }
        else                                      { $o.Luz='verde';   $o.Resumo=if($mbps -ne $null){"internet ok ($mbps Mbps)"}else{'internet ok'} }
    }
    elseif ($okGw)  { $o.Luz='amarelo';  $o.Resumo='chega no roteador, sem internet' }
    else            { $o.Luz='vermelho'; $o.Resumo='sem conexao' }
    return $o
}

# ===================== RODAR =====================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Passo 'Bateria...';                 $RES.Add((Test-Bateria))
Passo 'Dispositivos (teclado/mouse)...'; $RES.Add((Test-Dispositivos))
Passo 'Rede...';                    $RES.Add((Test-Rede))
$RES.Add((Test-Carga))   # ja imprime seu proprio progresso
$RES.Add((Test-Camera))
$RES.Add((Test-Som))

# ===================== RELATORIO (pasta no Desktop) =====================
$ordemLuz = @{ 'vermelho'=0; 'amarelo'=1; 'verde'=2; 'cinza'=3 }
$pior = ($RES | Sort-Object { $ordemLuz[$_.Luz] } | Select-Object -First 1).Luz
$veredito = switch ($pior) {
    'verde'    { 'PRONTO - pode ir para o estoque / ser entregue.' }
    'amarelo'  { 'ATENCAO - funciona, mas tem item(ns) a avaliar antes de entregar.' }
    'vermelho' { 'NAO ENTREGAR ainda - tem problema a resolver.' }
    default    { 'INCONCLUSIVO - rode como administrador para completar.' }
}

$txt = Join-Path $PASTA ("avaliacao-pc-{0}-{1}.txt" -f $HOST_NOME, $CARIMBO)
$L = [System.Collections.Generic.List[string]]::new()
function W($s) { [void]$L.Add($s) }
W ("=" * 64)
W "AVALIACAO DE PC - IG Networks / TI"
W ("PC: {0}   Usuario: {1}   Data: {2}" -f $HOST_NOME, $USUARIO, $AGORA.ToString('dd/MM/yyyy HH:mm'))
$sis = Safe { Get-CimInstance Win32_ComputerSystem }; $bios = Safe { Get-CimInstance Win32_BIOS }
if ($sis)  { W ("Modelo: {0} {1}" -f $sis.Manufacturer, $sis.Model) }
if ($bios) { W ("Serial: {0}" -f $bios.SerialNumber) }
W ("=" * 64)
W ""
W ("VEREDITO: " + $veredito)
W ""
W "RESUMO (semaforo):"
foreach ($r in $RES) { W ("  [{0,-8}] {1,-24} {2}" -f $r.Luz.ToUpper(), $r.Nome, $r.Resumo) }
W ""
W ("=" * 64)
W "DETALHE POR ITEM"
W ("=" * 64)
foreach ($r in $RES) {
    W ""
    W ("### {0}  ->  {1} ({2})" -f $r.Nome, $r.Luz.ToUpper(), $r.Resumo)
    foreach ($ln in $r.Linhas) { W ("    " + $ln) }
}
W ""
W ("=" * 64)
W "PARA UMA IA INTERPRETAR"
W ("=" * 64)
W "Voce e um tecnico de TI. Acima esta a avaliacao de um notebook que vai para"
W "o estoque ou para outra pessoa. Para cada item com luz AMARELO ou VERMELHO,"
W "diga em 1 linha o que provavelmente e e o que fazer antes de entregar."
W "Priorize o que impede a entrega. Responda em portugues, curto."
Safe { $L | Out-File -FilePath $txt -Encoding UTF8 }

Write-Host ""
Write-Host "  VEREDITO: $veredito" -ForegroundColor $(if($pior -eq 'verde'){'Green'}elseif($pior -eq 'vermelho'){'Red'}else{'Yellow'})
Write-Host "  Relatorio: $txt" -ForegroundColor Gray
Write-Host ""

# ===================== JANELA RESUMO (so luzes) =====================
$cor = @{ 'verde'=[System.Drawing.Color]::FromArgb(40,167,69); 'amarelo'=[System.Drawing.Color]::FromArgb(200,140,0); 'vermelho'=[System.Drawing.Color]::FromArgb(200,40,40); 'cinza'=[System.Drawing.Color]::Gray }
$palavra = @{ 'verde'='OK'; 'amarelo'='ATENCAO'; 'vermelho'='PROBLEMA'; 'cinza'='N/A' }

$f = New-Object System.Windows.Forms.Form
$f.Text = "Avaliacao - $HOST_NOME"
$f.StartPosition = 'CenterScreen'
$f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
$f.AutoScaleMode = 'None'
$f.BackColor = [System.Drawing.Color]::White
$f.ClientSize = New-Object System.Drawing.Size(430, (120 + $RES.Count * 32 + 70))

$hdr = New-Object System.Windows.Forms.Label
$hdr.Location = New-Object System.Drawing.Point(16,14); $hdr.AutoSize = $false
$hdr.Size = New-Object System.Drawing.Size(400,52)
$hdr.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
$hdr.Text = $veredito
$hdr.ForeColor = $cor[$pior]
$f.Controls.Add($hdr)

# cada linha e UM rotulo colorido (bolinha + nome + palavra) - texto e bolinha na mesma cor
$y = 78
foreach ($r in $RES) {
    $row = New-Object System.Windows.Forms.Label
    $row.Location = New-Object System.Drawing.Point(24,$y); $row.AutoSize = $false
    $row.Size = New-Object System.Drawing.Size(390,26)
    $row.Font = New-Object System.Drawing.Font('Segoe UI',11,[System.Drawing.FontStyle]::Bold)
    $row.ForeColor = $cor[$r.Luz]
    $row.TextAlign = 'MiddleLeft'
    $row.Text = ("{0}  {1}  -  {2}" -f ([char]0x25CF), $r.Nome, $palavra[$r.Luz])
    $f.Controls.Add($row)
    $y += 32
}
$y += 10

$btnPasta = New-Object System.Windows.Forms.Button
$btnPasta.Location = New-Object System.Drawing.Point(24,$y); $btnPasta.Size = New-Object System.Drawing.Size(220,36)
$btnPasta.Text = 'Abrir pasta do relatorio'; $btnPasta.Font = New-Object System.Drawing.Font('Segoe UI',9)
$btnPasta.Add_Click({ Safe { Start-Process explorer.exe $PASTA } })
$f.Controls.Add($btnPasta)

$btnOk = New-Object System.Windows.Forms.Button
$btnOk.Location = New-Object System.Drawing.Point(304,$y); $btnOk.Size = New-Object System.Drawing.Size(110,36)
$btnOk.Text = 'Fechar'; $btnOk.Font = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$btnOk.Add_Click({ $f.Close() }); $f.Controls.Add($btnOk)

[void]$f.ShowDialog()

# contador de uso (nao manda nada do conteudo)
Safe { Invoke-RestMethod -Uri "https://script.google.com/macros/s/AKfycbxCNI2nrcb-mDEMrSi9cmFfrvPBOT3T3MmwnnmNfWnbisdUqZDay59-eok7tg9p9varRg/exec?script=avaliar-pc" -TimeoutSec 8 | Out-Null }
