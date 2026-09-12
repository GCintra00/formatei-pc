#Requires -RunAsAdministrator
# disk-toolkit.ps1
# Canivete suico de manutencao de disco no Windows
# Funcionalidades: info SMART, format/partition, manutencao, backup, gestao de usuarios
# Funciona via arquivo (.\disk-toolkit.ps1) ou pipe (irm ... | iex)

# ============= Runtime admin check =============
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "ERRO: Este script precisa rodar como Administrador." -ForegroundColor Red
    Write-Host "Abra o PowerShell como administrador e tente novamente." -ForegroundColor Yellow
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============= Estado global =============
$script:currentAction = $null
$script:disksCache = @()

# ============= Helpers =============

function Get-SystemDiskNumber {
    try {
        $sysDrive = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name SystemRoot -ErrorAction Stop).SystemRoot.Substring(0,1)
        $partition = Get-Partition -DriveLetter $sysDrive -ErrorAction Stop
        return $partition.DiskNumber
    } catch {
        $bootDisk = Get-Disk | Where-Object { $_.IsBoot -or $_.IsSystem } | Select-Object -First 1
        if ($bootDisk) { return $bootDisk.Number }
        return -1
    }
}

function Get-AllDisks { return Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' } }

function Get-NonSystemDisks {
    $sys = Get-SystemDiskNumber
    return Get-AllDisks | Where-Object { $_.Number -ne $sys }
}

function Set-Status($text, $color) {
    $script:statusLabel.Text = $text
    $script:statusLabel.ForeColor = $color
    $script:form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-Msg($text, $title='Info', $icon='Information') {
    [System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon) | Out-Null
}

function Confirm-Action($text, $title='Confirmar') {
    return ([System.Windows.Forms.MessageBox]::Show($text, $title, 'YesNo', 'Warning') -eq 'Yes')
}

function Format-Bytes($bytes) {
    if ($bytes -ge 1TB) { return "{0:N2} TB" -f ($bytes / 1TB) }
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    return "{0:N0} bytes" -f $bytes
}

function Set-Output($text) {
    # WinForms TextBox so quebra linha com CRLF; normaliza qualquer LF puro -> CRLF
    $script:ctx.output.Text = (($text -replace "`r`n", "`n") -replace "`n", "`r`n")
}

function Fmt-Val($v, $suffix = '') {
    if ($null -eq $v -or "$v".Trim() -eq '') { return 'N/D' }
    return "$v$suffix"
}

# Como Fmt-Val, mas se nao houver valor distingue "nao se aplica" (N/A) de
# "nao reportado" (N/D). Ex.: desgaste em HDD = N/A; setor realocado em NVMe = N/A.
function Fmt-Field($v, $suffix = '', $notApplicable = $false) {
    if ($null -ne $v -and "$v".Trim() -ne '') { return "$v$suffix" }
    if ($notApplicable) { return 'N/A' }
    return 'N/D'
}

function Get-RawSmart($diskNum) {
    # Le SMART cru via WMI (root\wmi). Funciona em Win10/11 mesmo quando
    # Get-StorageReliabilityCounter vem vazio. Retorna hashtable ou $null.
    $res = @{ PredictFailure = $null; Reason = $null; Attrs = @{} }
    try {
        $dd = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.Index -eq $diskNum }
        if (-not $dd) { return $null }
        # Normaliza: tira sufixo de instancia (_0, _1...) e qualquer separador.
        # Comparacao exata era fragil (casava no HDD, falhava no SSD).
        $pnpKey = ((($dd.PNPDeviceID) -replace '_\d+$', '') -replace '[^A-Za-z0-9]', '').ToLower()

        $matchInst = {
            param($inst)
            $k = (($inst.InstanceName -replace '_\d+$', '') -replace '[^A-Za-z0-9]', '').ToLower()
            return ($k -eq $pnpKey)
        }

        $status = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
        if ($status) {
            $s = $status | Where-Object { & $matchInst $_ } | Select-Object -First 1
            if (-not $s -and @($status).Count -eq 1) { $s = @($status)[0] }
            if ($s) { $res.PredictFailure = $s.PredictFailure; $res.Reason = $s.Reason }
        }

        $pdata = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictData -ErrorAction SilentlyContinue
        if ($pdata) {
            $p = $pdata | Where-Object { & $matchInst $_ } | Select-Object -First 1
            if (-not $p -and @($pdata).Count -eq 1) { $p = @($pdata)[0] }
            if ($p -and $p.VendorSpecific) {
                $vs = $p.VendorSpecific
                # 2 bytes de versao, depois ate 30 atributos de 12 bytes cada
                for ($i = 2; ($i + 11) -lt $vs.Length -and $i -lt 362; $i += 12) {
                    $id = [int]$vs[$i]
                    if ($id -eq 0) { continue }
                    $raw = [int64]0
                    for ($j = 0; $j -lt 6; $j++) { $raw += ([int64]$vs[$i + 5 + $j]) -shl (8 * $j) }
                    $res.Attrs[$id] = @{ Value = [int]$vs[$i + 3]; Worst = [int]$vs[$i + 4]; Raw = $raw }
                }
            }
        }
        return $res
    } catch { return $null }
}

# --- Mapeamento disco <-> letra e interpretacoes (usado em varias telas) ---
function Get-DiskLettersMap {
    # DiskNumber -> "C:, D:"
    $map = @{}
    Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object {
        $n = [int]$_.DiskNumber
        if (-not $map.ContainsKey($n)) { $map[$n] = @() }
        $map[$n] += "$($_.DriveLetter):"
    }
    $out = @{}
    foreach ($k in $map.Keys) { $out[$k] = ($map[$k] -join ', ') }
    return $out
}

function Get-LetterDiskInfo($letter) {
    # Para um volume, devolve "Disk N - Modelo - Bus" do disco fisico onde ele mora
    try {
        $p = Get-Partition -DriveLetter $letter -ErrorAction Stop
        $n = [int]$p.DiskNumber
        $d = Get-Disk -Number $n -ErrorAction Stop
        $phys = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $n }
        $bus = if ($phys) { $phys.BusType } else { $d.BusType }
        return "Disk $n - $($d.FriendlyName) - $bus"
    } catch { return $null }
}

function Get-VolumeMediaType($letter) {
    # 'HDD' / 'SSD' / 'Desconhecido' para o disco fisico de um volume
    try {
        $n = (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber
        $mt = (Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $n }).MediaType
        if ("$mt" -eq 'HDD') { return 'HDD' }
        if ("$mt" -eq 'SSD') { return 'SSD' }
        return 'Desconhecido'
    } catch { return 'Desconhecido' }
}

function Get-FragPct($letter) {
    # Le % de fragmentacao via 'defrag /A'. Best-effort e tolerante a idioma:
    # pega o % numa linha que contenha "fragment" (raiz comum a EN/PT/ES). N/D se nao achar.
    try {
        $txt = (& defrag "${letter}:" /A 2>&1 | Out-String)
        $best = $null
        foreach ($line in ($txt -split "`n")) {
            if ($line -imatch 'fragment') {
                $m = [regex]::Match($line, '(\d+)\s*%')
                if ($m.Success) {
                    $v = [int]$m.Groups[1].Value
                    if ($null -eq $best -or $v -gt $best) { $best = $v }
                }
            }
        }
        return $best
    } catch { return $null }
}

function Get-LifeBand($pct) {
    # Faixa qualitativa de vida util restante (SSD/NVMe)
    if ($null -eq $pct) { return $null }
    if ($pct -ge 90) { return 'excelente' }
    if ($pct -ge 70) { return 'saudavel' }
    if ($pct -ge 40) { return 'uso moderado' }
    if ($pct -ge 20) { return 'desgaste alto - planejar troca' }
    return 'CRITICO - trocar'
}

function Get-TempTag($c) {
    if ($null -eq $c) { return $null }
    if ($c -le 55) { return 'ok' }
    if ($c -le 65) { return 'morno' }
    return 'quente'
}

function Get-HoursAge($h) {
    # "25314 h (~2,9 anos)"
    if ($null -eq $h) { return $null }
    $anos = [math]::Round($h / 8760.0, 1)
    return "$h h (~$anos anos)"
}

function Get-DiskDropdownItems($includeSystem=$false) {
    $disks = if ($includeSystem) { Get-AllDisks } else { Get-NonSystemDisks }
    $lettersMap = Get-DiskLettersMap
    # modelos repetidos -> desambiguar com pedaco do serial
    $dupModels = @($disks | Group-Object FriendlyName | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    $items = @()
    foreach ($d in $disks) {
        $name = $d.FriendlyName
        if (($dupModels -contains $name) -and $d.SerialNumber) {
            $sn = "$($d.SerialNumber)".Trim()
            $tail = if ($sn.Length -gt 5) { $sn.Substring($sn.Length - 5) } else { $sn }
            $name = "$name (SN..$tail)"
        }
        $letters = if ($lettersMap.ContainsKey([int]$d.Number)) { "  [$($lettersMap[[int]$d.Number])]" } else { "  [sem letra]" }
        $items += [PSCustomObject]@{
            Number = $d.Number
            Display = "Disk $($d.Number) - $name - $(Format-Bytes $d.Size) ($($d.BusType))$letters"
        }
    }
    return $items
}

function Get-VolumeDropdownItems {
    $vols = Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem }
    $items = @()
    foreach ($v in $vols) {
        $diskInfo = Get-LetterDiskInfo $v.DriveLetter
        $tail = if ($diskInfo) { "   -> [$diskInfo]" } else { "" }
        $items += [PSCustomObject]@{
            Letter = $v.DriveLetter
            Display = "$($v.DriveLetter): - $($v.FileSystemLabel) - $(Format-Bytes $v.Size) - $($v.FileSystem)$tail"
        }
    }
    return $items
}

# ============= CALOR / ENERGIA (so leitura) =============
# Devolve as linhas do laudo termico. Nasceu do caso do Vivobook da marellano
# (21/08/2026): "esquenta muito" so sai do achismo medindo temperatura, clock,
# evento de firmware e desligamento sujo - nada disso a gente ve no olho.
function Get-TermicoLinhas {
    param([switch]$ComDisco)
    $L = New-Object System.Collections.ArrayList
    function A($t) { [void]$L.Add($t) }
    $d30 = (Get-Date).AddDays(-30)

    # --- firmware: BIOS velha e' causa classica de fan burro e clock preso ---
    try {
        $b = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $meses = [math]::Round(((Get-Date) - $b.ReleaseDate).TotalDays / 30)
        $fl = if ($meses -ge 12) { " <- $meses meses de idade: procurar BIOS nova (MyASUS / site do fabricante)" } else { '' }
        A ("BIOS: {0} de {1:dd/MM/yyyy}{2}" -f $b.SMBIOSBIOSVersion, $b.ReleaseDate, $fl)
    } catch {}

    # --- carga atual + throttling (clock em % do nominal) ---
    $carga = $null
    try {
        $perf = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop | Where-Object Name -eq '_Total'
        $carga = [int]$perf.PercentProcessorTime
        $clock = [int]$perf.PercentProcessorPerformance
        $fl = if ($clock -lt 40 -and $carga -gt 50) { ' <- CPU FREADA sob carga (calor ou driver)' } else { '' }
        A ("CPU agora: carga {0}% | clock {1}% do nominal{2}" -f $carga, $clock, $fl)
    } catch {}

    # --- temperatura: nem todo notebook expoe ACPI (ai so HWiNFO ve) ---
    $tMax = $null
    $tz = $null
    try { $tz = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop } catch {}
    if ($tz) {
        foreach ($z in $tz) {
            $c = [math]::Round(($z.CurrentTemperature / 10) - 273.15, 1)
            if ($null -eq $tMax -or $c -gt $tMax) { $tMax = $c }
            A ("Temperatura {0}: {1} C (desliga em {2} C)" -f ($z.InstanceName -replace '.*\\', ''), $c, [math]::Round(($z.CriticalTripPoint / 10) - 273.15))
        }
    } else {
        A 'Temperatura: este modelo nao expoe ACPI -> medir com HWiNFO64 portable (aba Sensors)'
    }

    # veredito termico: o que importa e' a temperatura CRUZADA com a carga
    if ($null -ne $tMax) {
        $ocioso = ($null -eq $carga) -or ($carga -lt 25)
        if     ($tMax -ge 90)                { A "  VEREDITO: MUITO QUENTE ($tMax C) - risco de desligar sozinho. Limpar ventoinha + pasta termica." }
        elseif ($tMax -ge 70 -and $ocioso)   { A "  VEREDITO: QUENTE EM REPOUSO ($tMax C com CPU quase parada) - deveria estar em 45-55 C. Ventoinha entupida/pasta seca ou BIOS velha." }
        elseif ($tMax -ge 80)                { A "  VEREDITO: quente ($tMax C), mas sob carga de $carga% - aceitavel se cair rapido ao parar." }
        elseif ($tMax -ge 60 -and $ocioso)   { A "  VEREDITO: morno demais parado ($tMax C) - vigiar; se subir de 70 C, limpeza fisica." }
        else                                 { A "  VEREDITO: temperatura OK ($tMax C)." }
    }

    if ($ComDisco) {
        try {
            Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
                $r = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                A ("Disco: {0} | Saude: {1} | Temp: {2} C | Temp MAX: {3} C | Desgaste: {4}%" -f $_.FriendlyName, $_.HealthStatus, "$($r.Temperature)", "$($r.TemperatureMax)", "$($r.Wear)")
            }
            A '  (NVMe parado: 35-45 C normal; 60+ = calor preso na carcaca; 70+ quente)'
        } catch {}
    }

    # --- firmware freando a CPU: 37/38 = limitada pelo firmware, 55 = engine de energia resetada ---
    try {
        $kp = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Processor-Power'; StartTime=$d30} -ErrorAction Stop
        if ($kp) {
            # O Windows registra UM evento POR NUCLEO LOGICO na mesma rajada, entao o
            # total assusta a toa: num i9 de 24 threads, 168 "ocorrencias" sao 7 boots.
            # Agrupar por MINUTO da o numero de vezes que realmente aconteceu.
            $nThreads = [int]$env:NUMBER_OF_PROCESSORS; if ($nThreads -lt 1) { $nThreads = 1 }
            $kp | Group-Object Id | Sort-Object Name | ForEach-Object {
                $sig = switch ($_.Name) {
                    '37' { 'CPU limitada PELO FIRMWARE (BIOS/EC) - atualizar BIOS' }
                    '38' { 'CPU voltou ao normal depois de limitada' }
                    '55' { 'gerenciamento de energia resetado por defeito de firmware - atualizar BIOS' }
                    default { 'ver descricao no Visualizador de Eventos' }
                }
                $rajadas = @($_.Group | Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') })
                $porRaj  = if ($rajadas.Count) { [int](($rajadas | Measure-Object -Property Count -Average).Average) } else { 0 }
                A ("Kernel-Processor-Power ID {0}: {1}x em 30 dias - {2}" -f $_.Name, $_.Count, $sig)
                if ($rajadas.Count -and $rajadas.Count -lt $_.Count) {
                    A ("   -> sao {0} RAJADA(S) de ~{1} eventos (a maquina tem {2} threads)" -f $rajadas.Count, $porRaj, $nThreads)
                    if ($porRaj -ge ($nThreads - 2)) {
                        A '   -> ~1 evento POR NUCLEO: padrao de boot. Contar RAJADAS, nao eventos.'
                    }
                }
            }
        } else { A 'Freio termico/firmware: nenhum evento em 30 dias (bom sinal)' }
    } catch { A 'Freio termico/firmware: nenhum evento em 30 dias (bom sinal)' }

    # --- WHEA: erro de HARDWARE de verdade (nao e' software) ---
    try {
        $whea = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$d30} -ErrorAction Stop)
        if ($whea.Count -gt 0) {
            A ("WHEA (ERRO DE HARDWARE): {0} evento(s) em 30 dias - ultimo {1:dd/MM HH:mm} <- se coincidir com desligamento, foi hardware" -f $whea.Count, $whea[0].TimeCreated)
        } else { A 'WHEA (erro de hardware): nenhum em 30 dias' }
    } catch { A 'WHEA (erro de hardware): nenhum em 30 dias' }

    # --- desligamentos sujos: 41 e 6008 sao O MESMO evento visto de 2 angulos.
    #     Contar os dois separado inflava o numero (bug do laudo de 20/08: "4" eram 2).
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6008; StartTime=$d30} -ErrorAction Stop)
        $momentos = @($ev | Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') })
        $fl = if ($momentos.Count -gt 3) { ' <- SUSPEITO (causa classica de corrupcao do repositorio de componentes)' } else { '' }
        A ("Desligamentos SUJOS em 30 dias: {0}{1}" -f $momentos.Count, $fl)
        foreach ($m in ($momentos | Select-Object -First 6)) {
            $e41 = $m.Group | Where-Object Id -eq 41 | Select-Object -First 1
            $bug = if ($e41) { "$($e41.Properties[1].Value)" } else { 'N/D' }
            $pwr = if ($e41) { "$($e41.Properties[4].Value)" } else { 'N/D' }
            $lei = if ($bug -ne '0' -and $bug -ne 'N/D') { 'tela azul (driver)' }
                   elseif ($pwr -ne '0' -and $pwr -ne 'N/D') { 'botao de energia segurado' }
                   else { 'queda seca: energia, calor ou hardware' }
            A ("  {0} | Bugcheck {1} | {2}" -f $m.Name, $bug, $lei)
        }
    } catch { A 'Desligamentos sujos: (sem dados)' }
    try {
        $md = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -ErrorAction Stop)
        if ($md.Count -gt 0) { A ("Minidumps de tela azul: {0} (ultimo: {1})" -f $md.Count, ($md | Sort-Object LastWriteTime | Select-Object -Last 1).Name) }
    } catch {}

    # --- bateria: saude real = capacidade atual / capacidade de fabrica ---
    try {
        $des = (Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
        $ful = (Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
        $cic = (Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Select-Object -First 1).CycleCount
        if ($des -gt 0 -and $ful -gt 0) {
            $sau = [math]::Round(100 * $ful / $des)
            $fl = if ($sau -lt 60) { ' <- GASTA, trocar' } elseif ($sau -lt 80) { ' <- desgaste normal de uso' } else { '' }
            A ("Bateria: saude {0}% ({1} de {2} mWh) | ciclos: {3}{4}" -f $sau, $ful, $des, $(if ($cic) { $cic } else { 'N/D' }), $fl)
        }
    } catch { A 'Bateria: sem dados de capacidade (desktop, ou driver nao expoe)' }
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($bat) { A ("Carga atual: {0}% | {1}" -f $bat.EstimatedChargeRemaining, $(if ($bat.BatteryStatus -eq 2) { 'na tomada' } else { 'na bateria' })) }
    } catch {}

    # --- quem esta gerando o calor ---
    try {
        A 'Top 5 CPU agora (nome | CPU em segundos | RAM MB):'
        Get-Process -ErrorAction Stop | Sort-Object CPU -Descending | Select-Object -First 5 |
            ForEach-Object { A ("  {0} | {1} s | {2} MB" -f $_.Name, [math]::Round($_.CPU), [math]::Round($_.WS / 1MB)) }
    } catch {}

    return $L
}

# ============= ENERGIA / CLOCK DA CPU (mede -> libera -> mede) =============
# Nasceu do PC parado em 0,44 GHz: clock BAIXO nao e' sintoma, clock que NAO SOBE e'.
# O % do Gerenciador de Tarefas engana (e' relativo ao clock ATUAL), por isso aqui
# tudo e' medido em PercentProcessorPerformance (% do clock nominal).
$script:EN = @{
    SubProc  = '54533251-82be-4824-96c1-47b60b740d00'   # gerenciamento de energia do processador
    ThrotMax = 'bc5038f7-23e0-4960-96da-33abaf5935ec'   # estado maximo do processador (o teto que a UI do Win11 esconde)
    ThrotMin = '893dee8e-2bef-41e0-89c6-b55d0929964c'   # estado minimo
    Boost    = 'be337238-0d82-4146-a960-4f3749d470c7'   # turbo
    SubSaver = 'de830923-a562-41af-a086-e3a2c6bad2da'   # economia de energia (Win11)
    EsThresh = 'e69653ca-cf7f-4f05-aa73-cb833fa90ad4'   # em que % de carga ela liga sozinha
    OvlPerf  = 'ded574b5-45a0-4f42-8737-46345c09c238'   # slider "Melhor desempenho"
    OvlEfic  = '961cc777-2547-4f9d-8174-7d86181b8a7a'   # slider "Melhor eficiencia" (freia a CPU)
    Bal      = '381b4222-f694-41f0-9685-ff5bb260df2e'   # plano Equilibrado
    Saver    = 'a1841308-3541-4fab-bc81-f71556f20b4a'   # plano Economia de energia
    SubPcie  = '501a4d13-42af-4429-9fd1-a8218c268e20'   # PCI Express
    Aspm     = 'ee12f906-d277-404b-b6da-e5fa1a576df5'   # link state power management (ASPM)
}

function Invoke-Powercfg {
    param([string[]]$Args1)
    try { return ((& "$env:SystemRoot\System32\powercfg.exe" @Args1 2>&1) -join "`n") } catch { return '' }
}

function Get-PowercfgHex2($texto) {
    # PEGADINHA: o /q imprime "valor minimo/maximo possivel" ANTES do indice de CA/CC.
    # Os indices AC e DC sao os DOIS ULTIMOS hex - assim vale em PT, ES e EN.
    $m = @([regex]::Matches("$texto", '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt32($_.Value, 16) })
    if ($m.Count -ge 2) { return @($m[$m.Count - 2], $m[$m.Count - 1]) }
    return @(-1, -1)
}

function Get-EnergiaValor($subGuid, $setGuid) {
    return (Get-PowercfgHex2 (Invoke-Powercfg @('/q', 'SCHEME_CURRENT', $subGuid, $setGuid)))
}

function Get-PastaBackup {
    # Todo arquivo que o canivete gera vai para Desktop\UTI-backup, a MESMA pasta
    # que a UTI cria - assim a evidencia do atendimento fica junta e o Desktop limpo.
    # A UTI so existe se alguem a rodou, entao aqui a pasta e criada se faltar.
    $d = [Environment]::GetFolderPath('Desktop')
    if (-not $d -or -not (Test-Path $d)) { $d = Join-Path $env:USERPROFILE 'Desktop' }
    if (-not (Test-Path $d)) { $d = $env:USERPROFILE }
    $alvo = Join-Path $d 'UTI-backup'
    try { if (-not (Test-Path $alvo)) { New-Item -ItemType Directory -Path $alvo -Force -EA Stop | Out-Null } }
    catch { return $d }   # nao conseguiu criar: cai para o Desktop, nao perde o arquivo
    return $alvo
}

function Get-ClockAgora {
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop | Where-Object Name -eq '_Total'
        if ($p) { return @{ Perf = [double]$p.PercentProcessorPerformance; Uso = [double]$p.PercentProcessorTime } }
    } catch {}
    try {
        $c = Get-Counter '\Processor Information(_Total)\% of Maximum Frequency' -ErrorAction Stop
        if ($c) { return @{ Perf = [double]$c.CounterSamples[0].CookedValue; Uso = -1 } }
    } catch {}
    return $null
}

function Get-ClockGhz($perf) {
    $mhz = 0
    try { $mhz = (Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).MaxClockSpeed } catch {}
    if ($mhz -gt 0) { return [math]::Round(($mhz * $perf / 100) / 1000, 2) }
    return 0
}

function Test-CargaClock {
    # Poe carga em todos os nucleos e devolve o MAIOR clock visto. E' o teste que separa
    # "ocioso a 0,4 GHz" (normal) de "PRESO a 0,4 GHz" (defeito): sob carga tem que subir.
    param([int]$Segundos = 10, [string]$Rotulo = '')
    $n = [int]$env:NUMBER_OF_PROCESSORS; if ($n -lt 1) { $n = 2 }
    $jobs = @()
    for ($i = 0; $i -lt $n; $i++) {
        $jobs += Start-Job -ScriptBlock { param($s) $fim = (Get-Date).AddSeconds($s); $x = 1.0; while ((Get-Date) -lt $fim) { $x = [math]::Sqrt($x + 1.234567) } } -ArgumentList ($Segundos + 3)
    }
    Start-Sleep -Seconds 3
    $picoPerf = 0.0; $picoUso = 0.0
    for ($i = 1; $i -le $Segundos; $i++) {
        $m = Get-ClockAgora
        if ($m) {
            if ($m.Perf -gt $picoPerf) { $picoPerf = $m.Perf }
            if ($m.Uso  -gt $picoUso)  { $picoUso  = $m.Uso }
        }
        Set-Status ("Carga $Rotulo em $n nucleos... ${i}/$Segundos s | pico {0}% do nominal" -f [math]::Round($picoPerf)) ([System.Drawing.Color]::DarkOrange)
        Start-Sleep -Seconds 1
    }
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    return @{ Perf = $picoPerf; Uso = $picoUso }
}

function Get-EnergiaConfigLinhas {
    $L = New-Object System.Collections.ArrayList
    function A($t) { [void]$L.Add($t) }

    $plano = Invoke-Powercfg @('/getactivescheme')
    A ("Plano ativo: " + (($plano -replace '\s+', ' ').Trim()))

    $t = Get-EnergiaValor $script:EN.SubProc $script:EN.ThrotMax
    $fl = if ($t[0] -ge 100 -and $t[1] -ge 100) { '' } else { ' <- TETO BAIXO: e a causa mais comum, a UI do Win11 esconde isso' }
    A ("Teto do processador: AC {0}% | bateria {1}%{2}" -f $t[0], $t[1], $fl)

    $mn = Get-EnergiaValor $script:EN.SubProc $script:EN.ThrotMin
    if ($mn[0] -ge 0) { A ("Piso do processador: AC {0}% | bateria {1}%" -f $mn[0], $mn[1]) }

    $bo = Get-EnergiaValor $script:EN.SubProc $script:EN.Boost
    if ($bo[0] -ge 0) {
        $fl = if ($bo[0] -eq 0) { ' <- TURBO DESLIGADO' } else { '' }
        A ("Turbo (boost): AC {0} | bateria {1}{2}" -f $bo[0], $bo[1], $fl)
    }

    $es = Get-EnergiaValor $script:EN.SubSaver $script:EN.EsThresh
    if ($es[0] -ge 0) { A ("Economia de energia liga em: AC {0}% | bateria {1}% de carga (0 = nunca sozinha)" -f $es[0], $es[1]) }

    $ovl = $null
    try { $ovl = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' -Name ActiveOverlayAcPowerScheme -ErrorAction Stop).ActiveOverlayAcPowerScheme } catch {}
    $nomeOvl = switch ("$ovl") {
        $script:EN.OvlPerf { 'Melhor desempenho' }
        $script:EN.OvlEfic { 'Melhor eficiencia <- FREIA A CPU' }
        ''                 { 'recomendado/equilibrado' }
        default            { "$ovl" }
    }
    A ("Slider de desempenho (overlay): $nomeOvl")

    $pt = 'ausente (= ligado, padrao do Windows)'
    try { $pt = "$((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Name PowerThrottlingOff -ErrorAction Stop).PowerThrottlingOff)" } catch {}
    A ("Power Throttling (freio de apps em 2o plano): PowerThrottlingOff = $pt")

    $gpo = "HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\$($script:EN.ThrotMax)"
    if (Test-Path $gpo) {
        A 'POLITICA (GPO/registro) impondo teto de CPU <- powercfg NAO vence isso; remover a chave e reiniciar:'
        A "  Remove-Item '$gpo' -Recurse -Force"
    } else { A 'Politica de energia forcada por GPO/registro: nenhuma (bom)' }

    try {
        $mgr = @(Get-Service -ErrorAction Stop | Where-Object { $_.Status -eq 'Running' -and ($_.DisplayName -match 'Lenovo|Vantage|Intelligent|Dell|Power Manager|ASUS|Armoury|MyASUS|Dynamic Platform|DPTF' -or $_.Name -match 'esif|dptf|LenovoVantage|DellPower') })
        if ($mgr.Count -gt 0) {
            A ("Gerenciador de energia do FABRICANTE ativo ({0}) <- pode sobrepor o Windows:" -f $mgr.Count)
            $mgr | Select-Object -First 5 | ForEach-Object { A ("  {0} ({1})" -f $_.DisplayName, $_.Name) }
        } else { A 'Gerenciador de energia de fabricante: nenhum rodando' }
    } catch { A 'Gerenciador de energia de fabricante: NAO VERIFICADO (Get-Service falhou aqui)' }

    # Chassi ANTES de falar de bateria: "sem bateria" num NOTEBOOK e' achado, nao caracteristica.
    $portateis = @(8,9,10,11,12,14,18,21,30,31,32)
    $chassi = 0
    try { $chassi = [int](@((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)[0]) } catch {}
    $ehNote = ($portateis -contains $chassi)
    $temBat = $false
    try { $temBat = [bool](Get-CimInstance Win32_Battery -ErrorAction Stop) } catch {}
    $script:enSemBateria = ($ehNote -and -not $temBat)
    if ($script:enSemBateria) {
        A 'NOTEBOOK COM BATERIA NAO DETECTADA (morta, ausente ou circuito com defeito) <- fonte classica de BD PROCHOT:'
        A '  o sinal que, preso em alto, joga a CPU no multiplicador minimo e a mantem la, FRIA, e reboot NAO resolve'
    } elseif ($ehNote) { A 'Bateria: presente' } else { A ("Chassi: desktop ($chassi), sem bateria - normal") }

    return $L
}

# ============= WHEA / AER (tempestade de erro corrigido no link PCIe) =============
# Nasceu do Inspiron 5566 da Ju (07-08/09/2026): 11.719 eventos WHEA Id 17 ("corrigido")
# no PCI Express Root Port. Erro CORRIGIDO nao clampa clock - mas em massa e' tempestade,
# quase sempre ASPM, e ela ENCHE o log de Sistema e empurra a prova (evento 37) pra fora.
function Get-WheaLinhas {
    $L = New-Object System.Collections.ArrayList
    function A($t) { [void]$L.Add($t) }
    $d30 = (Get-Date).AddDays(-30)

    $whea = @()
    try { $whea = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$d30} -ErrorAction Stop) } catch {}
    if ($whea.Count -eq 0) {
        A 'WHEA (erro de hardware): nenhum evento em 30 dias. BOM SINAL.'
        $script:aerTempestade = $false
    } else {
        $corr  = @($whea | Where-Object { $_.Message -match 'corrigido|corregido|corrected' })
        $fatal = @($whea | Where-Object { $_.Message -match 'fatal|irrecuper|uncorrect' })
        A ("WHEA em 30 dias: {0} evento(s) -> {1} CORRIGIDO(S) | {2} FATAL(IS)" -f $whea.Count, $corr.Count, $fatal.Count)
        A ("Taxa: ~{0} por hora" -f [math]::Round($whea.Count / 720, 1))
        $whea | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object {
            $ex = ($_.Group[0].Message -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
            A ("  Id {0}: {1}x -> {2}" -f $_.Name, $_.Count, "$ex".Trim())
        }
        $comp = @($whea | ForEach-Object { if ($_.Message -match '(?im)^\s*Componen[^:]*:\s*(.+)$' -or $_.Message -match '(?im)^\s*Component[^:]*:\s*(.+)$') { $matches[1].Trim() } }) | Group-Object | Sort-Object Count -Descending
        foreach ($c in ($comp | Select-Object -First 3)) { A ("  componente: {0} ({1}x)" -f $c.Name, $c.Count) }
        $devs = @($whea | ForEach-Object { if ($_.Message -match 'PCI\\VEN_([0-9A-Fa-f]{4})&DEV_([0-9A-Fa-f]{4})') { "PCI\VEN_$($matches[1])&DEV_$($matches[2])" } }) | Group-Object | Sort-Object Count -Descending
        foreach ($d in ($devs | Select-Object -First 2)) {
            $nome = ''
            try { $nome = (Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.DeviceID -like "$($d.Name)*" } | Select-Object -First 1).Name } catch {}
            A ("  dispositivo: {0} ({1}x){2}" -f $d.Name, $d.Count, $(if ($nome) { " = $nome" } else { '' }))
        }
        if ($fatal.Count -gt 0) {
            A 'LEITURA: tem evento FATAL - erro de hardware que NAO recuperou. Isso e conversa de GARANTIA.'
        } else {
            A 'LEITURA: "corrigido" = o link errou e SE RECUPEROU. NAO clampa clock e nao e garantia.'
            A '         Em massa, porem, e tempestade: quase sempre ASPM (energia do link PCIe),'
            A '         ou Wi-Fi/NVMe mal assentado. Desligar o ASPM e o teste reversivel.'
        }
        $script:aerTempestade = ($whea.Count -ge 100 -and $fatal.Count -eq 0)
    }

    $aspm = Get-EnergiaValor $script:EN.SubPcie $script:EN.Aspm
    $nomes = @{0='desativado'; 1='economia moderada'; 2='economia maxima'}
    if ($aspm[0] -ge 0) {
        A ("ASPM (energia do link PCIe): AC = {0} | bateria = {1}" -f $nomes[[int]$aspm[0]], $nomes[[int]$aspm[1]])
        $script:aspmLigado = ($aspm[0] -ne 0 -or $aspm[1] -ne 0)
    } else { A 'ASPM: este plano nao expoe a configuracao de PCI Express'; $script:aspmLigado = $false }

    # profundidade do log: a tempestade apaga a prova
    try {
        $all = @(Get-WinEvent -LogName System -MaxEvents 20000 -ErrorAction Stop)
        A ("Log de Sistema: {0} eventos, o mais antigo de {1:dd/MM HH:mm}" -f $all.Count, $all[-1].TimeCreated)
        $top = $all | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 3
        foreach ($t in $top) { A ("  quem mais escreve: {0} ({1}x)" -f $t.Name, $t.Count) }
        if ($all.Count -ge 15000) { A '  <- log perto do limite: eventos antigos (evento 37 e cia) estao sendo APAGADOS' }
    } catch { A 'Log de Sistema: NAO VERIFICADO (leitura falhou aqui)' }

    return $L
}

function Set-AspmDesligado {
    $E = $script:EN
    Invoke-Powercfg @('/setacvalueindex', 'SCHEME_CURRENT', $E.SubPcie, $E.Aspm, '0') | Out-Null
    Invoke-Powercfg @('/setdcvalueindex', 'SCHEME_CURRENT', $E.SubPcie, $E.Aspm, '0') | Out-Null
    Invoke-Powercfg @('/setactive', 'SCHEME_CURRENT') | Out-Null
    $v = Get-EnergiaValor $E.SubPcie $E.Aspm
    return ($v[0] -eq 0 -and $v[1] -eq 0)
}

function Set-EnergiaLiberada {
    # Tudo reversivel e vale na hora, sem reiniciar.
    $L = New-Object System.Collections.ArrayList
    function A($t) { [void]$L.Add($t) }
    $E = $script:EN

    $plano = Invoke-Powercfg @('/getactivescheme')
    if ($plano -match $E.Saver) {
        Invoke-Powercfg @('/setactive', $E.Bal) | Out-Null
        A 'plano "Economia de energia" -> "Equilibrado"'
    }
    foreach ($fonte in @('/setacvalueindex', '/setdcvalueindex')) {
        Invoke-Powercfg @($fonte, 'SCHEME_CURRENT', $E.SubProc,  $E.ThrotMax, '100') | Out-Null
        Invoke-Powercfg @($fonte, 'SCHEME_CURRENT', $E.SubProc,  $E.ThrotMin, '5')   | Out-Null
        Invoke-Powercfg @($fonte, 'SCHEME_CURRENT', $E.SubProc,  $E.Boost,    '2')   | Out-Null
        Invoke-Powercfg @($fonte, 'SCHEME_CURRENT', $E.SubSaver, $E.EsThresh, '0')   | Out-Null
    }
    A 'teto do processador em 100% e piso em 5% (AC e bateria)'
    A 'turbo (boost) em modo agressivo'
    A 'economia de energia automatica desligada (limiar 0%)'
    Invoke-Powercfg @('/setactive', 'SCHEME_CURRENT') | Out-Null   # sem isto nada vale

    $r = Invoke-Powercfg @('/overlaysetactive', $script:EN.OvlPerf)
    if ($r -notmatch 'nvalid|rro') { A 'slider de desempenho em "Melhor desempenho"' }

    try {
        $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
        if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
        New-ItemProperty $k -Name PowerThrottlingOff -Value 1 -PropertyType DWord -Force | Out-Null
        A 'Power Throttling desligado (PowerThrottlingOff=1)'
    } catch { A "Power Throttling: falhou ($($_.Exception.Message))" }

    return $L
}

# ============= Cataloog de acoes =============
# Estrutura: nome interno, nome amigavel, categoria, descricao, funcao a chamar

$script:actions = @(
    # === AJUDA ===
    @{Id='helpcmds'; Name='Comandos (cheat sheet)'; Cat='AJUDA'; Desc='Lista de scripts disponiveis via "irm | iex" das contas GCintra00 (pessoal) e igcintra (empresa). Util pra lembrar rapido os outros comandos quando ta atendendo um PC. Clica "Rodar (nova janela)" pra executar ou "Copiar pro clipboard" pra colar no PowerShell.'},

    # === INFORMACAO ===
    @{Id='smart'; Name='S.M.A.R.T. (Saude do disco)'; Cat='INFORMACAO'; Desc='Le o status auto-reportado pelo proprio drive. Mostra saude geral (OK/Warning/Critical), horas de uso, temperatura, setores realocados e contagem de erros. Util pra detectar disco em pre-falha antes que dê problema serio.'},
    @{Id='info'; Name='Informacoes detalhadas'; Cat='INFORMACAO'; Desc='Mostra tudo que da pra saber sobre um disco: modelo, serial, firmware, tipo (HDD/SSD/NVMe), tabela (GPT/MBR), barramento (SATA/USB/NVMe), tamanho total, particoes existentes e seus filesystems.'},
    @{Id='overview'; Name='Visao geral - todos os discos'; Cat='INFORMACAO'; Desc='Lista TODOS os discos de uma vez numa tabela: numero, modelo, tipo (HDD/SSD/NVMe), saude, vida util (com faixa: excelente/saudavel/moderado/desgaste alto/critico) e as letras de cada disco. Responde num olhar "qual disco e qual" e "qual SSD esta mais gasto". Clique Executar pra atualizar.'},

    # === PARTICAO ===
    @{Id='wipe'; Name='Apagar e formatar (Wipe & Format)'; Cat='PARTICAO'; Desc='ATENCAO: Operacao destrutiva. Apaga TUDO do disco (partições, dados, recovery, OEM), cria nova tabela GPT, cria uma unica particao ocupando o disco inteiro e formata em NTFS. O modo normal e rapido (apaga a tabela). Marque "Formatacao SEGURA" pra ZERAR todos os setores (irrecuperavel por endereco) - so funciona em HD (em SSD e bloqueado) e pode levar HORAS num disco grande.'},
    @{Id='label'; Name='Trocar label do volume'; Cat='PARTICAO'; Desc='Renomeia o volume (ex: "HDD" para "Backup") sem precisar formatar nem perder nenhum dado. So muda o nome que aparece no Explorer.'},
    @{Id='letter'; Name='Trocar letra de drive'; Cat='PARTICAO'; Desc='Reatribui a letra do drive (ex: E: vira D:) sem mexer nos dados. Util quando o Windows escolhe uma letra esquisita ou voce quer organizar.'},
    @{Id='resize'; Name='Redimensionar particao'; Cat='PARTICAO'; Desc='Diminui ou aumenta o tamanho de uma particao existente, sem perder dados. Pra diminuir, precisa ter espaco livre no volume. Pra aumentar, precisa ter espaco nao alocado adjacente no disco.'},
    @{Id='format'; Name='Formatar com escolha de FS'; Cat='PARTICAO'; Desc='ATENCAO: Apaga todos os dados da particao escolhida. Diferente do Wipe&Format, este só reformata uma particao especifica (não mexe nas outras). Permite escolher entre NTFS, exFAT, FAT32 ou ReFS.'},

    # === MANUTENCAO ===
    @{Id='uti'; Name='UTI do Windows (limpeza + reparo profundo)'; Cat='MANUTENCAO'; Desc='Para PC travado/iniciando mal: mata todos os apps abertos (preserva acesso remoto), desintoxica a inicializacao (Steam etc, com backup no Desktop), limpa temp/caches/lixeira, cache do Windows Update, flush DNS + winsock reset, bateria DISM completa + SFC na ordem certa, chkdsk e defrag. Pergunta o modo na largada: watchdog (limite de tempo por etapa) ou log completo (pericia). Abre em janela propria elevada; REINICIAR o PC ao final. Roda direto do repo limpeza (GCintra00).'},
    @{Id='chkdsk'; Name='Checagem de integridade (CHKDSK)'; Cat='MANUTENCAO'; Desc='Roda CHKDSK pra verificar erros no sistema de arquivos da partição. Com o modo "Corrigir", tenta consertar erros encontrados e marcar setores defeituosos como inacessiveis. Recomenda agendar se o disco estiver em uso.'},
    @{Id='defrag'; Name='Desfragmentar / Otimizar'; Cat='MANUTENCAO'; Desc='Detecta automaticamente se o disco e HDD ou SSD. Em HDD: desfragmenta arquivos pra melhorar velocidade de leitura. Em SSD: roda TRIM (retorna celulas nao usadas pra controlador, mantem performance).'},
    @{Id='wipefree'; Name='Limpar espaco livre (impede recuperacao)'; Cat='MANUTENCAO'; Desc='Sobrescreve com zeros toda a area marcada como livre no disco. Arquivos que voce apagou antes mas que ainda existiam no disco (recuperaveis com software) deixam de existir. Util antes de doar/vender PC. Pode demorar bastante (1+ hora em discos grandes).'},

    # === BACKUP ===
    @{Id='backupuser'; Name='Backup arquivos de usuario'; Cat='BACKUP'; Desc='Copia pastas pessoais dos usuarios do Windows (Desktop, Documentos, Imagens, etc.) pra um disco destino. Voce escolhe quais perfis e quais pastas. Usa robocopy multi-thread (rapido + retoma se cair).'},
    @{Id='clonedados'; Name='Clonar disco de dados'; Cat='BACKUP'; Desc='Espelha o conteudo de um disco/volume em outro. NAO clona o disco do sistema (Windows nao deixa enquanto rodando). So pra discos de dados (D:, E:, etc.).'},
    @{Id='vhdx'; Name='Imagem VHDX (snapshot do C:)'; Cat='BACKUP'; Desc='Cria um arquivo .vhdx no disco destino contendo um snapshot do C: tirado a quente via VSS (sem desligar). Util como backup antes de operacoes arriscadas, ou pra recuperar dados se o Windows corromper depois. Use Disk2VHD da Sysinternals.'},

    # === USUARIOS ===
    @{Id='users'; Name='Listar e apagar perfis de usuario'; Cat='USUARIOS'; Desc='Lista todos os perfis locais do Windows com nome, tamanho ocupado em disco e ultimo login. Permite apagar perfis antigos (remove pasta C:\Users\xyz + conta + entrada no registro). Se o usuario escolhido estiver LOGADO, faz logoff forcado automaticamente antes de apagar. So bloqueia se voce tentar apagar sua propria conta (esta logada agora).'},
    @{Id='renameuser'; Name='Renomear pasta de perfil (C:\Users\xyz)'; Cat='USUARIOS'; Desc='Troca o nome da pasta do perfil (ex: C:\Users\CintrAvell -> C:\Users\acamargo), que renomear a CONTA nunca muda. Voce escolhe o perfil na lista e digita o nome novo. Faz na ordem segura: renomeia a pasta primeiro e SO depois aponta o registro (ProfileImagePath) pra ela - se a pasta estiver travada, nada e gravado, evitando o perfil temporario. Opcional: renomear tambem a conta local e criar um atalho (junction) com o nome antigo pra nao quebrar app com caminho fixo. Rode por OUTRA conta admin, com o perfil alvo deslogado, e reinicie antes de logar nele.'},
    @{Id='createuser'; Name='Criar novo usuario local'; Cat='USUARIOS'; Desc='Cria uma conta LOCAL do Windows (sem vinculo com conta Microsoft) com nome de usuario e senha definidos por voce. Opcionalmente da privilegio de Administrador. Util pra criar conta tecnica em PCs em manutencao ou conta nova pra um colaborador.'},

    # === REDE ===
    @{Id='share'; Name='Compartilhar pasta na rede (SMB)'; Cat='REDE'; Desc='Cria um compartilhamento SMB de uma pasta no PC, com usuario/senha de acesso. Configura permissoes NTFS, abre o firewall pra SMB e devolve o caminho UNC (\\IP\Nome) pra acessar de outras maquinas Windows. Util pra disponibilizar uma pasta de trabalho ou backup acessivel pela rede interna - estilo Move Docs.'},
    @{Id='listshares'; Name='Cortar compartilhamento de rede'; Cat='REDE'; Desc='Lista todos os compartilhamentos SMB ativos no PC (ocultos C$/ADMIN$ ja filtrados). Selecione um e clique Executar pra remove-lo. Nao apaga a pasta nem o usuario, so para de compartilhar.'},

    # === SISTEMA ===
    @{Id='activate'; Name='Ativar Windows (licenca da placa-mae)'; Cat='SISTEMA'; Desc='Le a chave OEM gravada no firmware da placa-mae (tabela MSDM) - a licenca que JA veio comprada com o PC - e mostra o status de ativacao, o tipo de licenca (OEM/Retail/Volume/KMS) e a validade (OEM/Retail = permanente, sem expiracao). Marque "Forcar reativacao" pra instalar a chave OEM e reativar (util apos reinstalar o Windows). Nao funciona em placa sem licenca embutida (avisa).'},
    @{Id='termico'; Name='Calor e bateria (temperatura + throttling)'; Cat='SISTEMA'; Desc='So leitura, nao muda nada. Responde "esta esquentando de mais?" com numero em vez de achismo: temperatura ACPI cruzada com a carga da CPU (74 C parado e problema, 74 C sob carga nao), clock em % do nominal pra ver se a CPU esta sendo freada, eventos de firmware limitando a CPU (37/38/55 - quase sempre BIOS velha), erro de hardware WHEA, desligamentos sujos com o BugcheckCode que separa tela azul de queda seca, minidumps, saude real da bateria (capacidade atual x de fabrica + ciclos) e quem esta comendo CPU. Da um VEREDITO por escrito. Opcional: relatorio de bateria em HTML no Desktop.'},
    @{Id='energia'; Name='Energia / clock da CPU (PC lento a 0,4 GHz)'; Cat='SISTEMA'; Desc='Para "o PC esta lento sem motivo": mede o clock REAL em % do nominal (o % do Gerenciador de Tarefas engana, e relativo ao clock atual), poe CARGA em todos os nucleos e ve se o clock SOBE - clock baixo nao e sintoma, clock que NAO SOBE e. Mostra como a energia esta: teto e piso do processador em AC e bateria (o teto que a UI do Win11 esconde), turbo, limiar da economia de energia, slider de desempenho, power throttling, politica por GPO e gerenciador do fabricante. Se "Liberar a energia" estiver marcado, aplica as correcoes (teto 100%, piso 5%, turbo agressivo, economia de energia so manual, plano Equilibrado, slider em Melhor desempenho, PowerThrottlingOff) e MEDE DE NOVO, dando o veredito: era configuracao, e limite termico/firmware, ou a CPU esta presa e a conversa passa a ser BIOS/EC/garantia. Tudo reversivel, vale na hora sem reiniciar. Opcional: log no Desktop.'},
    @{Id='checkup'; Name='Checkup comparativo (antes x depois)'; Cat='SISTEMA'; Desc='Para responder "aquilo que eu mexi resolveu?". Grava uma LINHA DE BASE na primeira rodada e, nas seguintes, imprime o ANTES x DEPOIS sozinho - nao precisa guardar nada. Mede: BIOS, memoria (avisa quando o XMP esta desligado e a RAM caiu para o JEDEC base - tipico depois de flashar a BIOS), os contadores que importam (Kernel-Processor-Power 55, WHEA, desligamentos sujos, falhas de Fast Startup, zona termica, minidumps) e o clock ocioso e sob carga. Conta o ID 55 por RAJADA, nao por evento. A metrica que fecha o caso e a ULTIMA OCORRENCIA de cada tipo: se ficou parada no dia em que voce mexeu, resolveu - o total nao serve, porque e janela movel de 30/90 dias. So leitura (o teste de carga usa a CPU por ~13 s).'},
    @{Id='aer'; Name='PCIe: tempestade de erro corrigido (WHEA)'; Cat='SISTEMA'; Desc='Para quando o Visualizador de Eventos vive cheio de WHEA-Logger. Conta os erros de hardware reportados em 30 dias e SEPARA o que importa: "corrigido" (o link errou e se recuperou - nao clampa clock, nao e garantia) de "fatal" (nao recuperou - conversa de garantia). Mostra por Id, o componente e o dispositivo PCI\VEN&DEV com o nome dele, o estado do ASPM (energia do link PCIe) em AC e bateria, e a PROFUNDIDADE do log de Sistema com quem mais escreve nele - porque tempestade de WHEA empurra a prova (o evento 37 de CPU limitada, por exemplo) pra fora do log antes de voce ler. Se marcar "Desligar o ASPM", aplica em AC e bateria (reversivel, precisa REINICIAR) - e a causa nº1 de tempestade de erro corrigido; se nao resolver, o proximo passo e fisico: reassentar Wi-Fi e NVMe.'},
    @{Id='repairboot'; Name='Reparar Boot / Sistema (DISM + SFC)'; Cat='SISTEMA'; Desc='Reparo ONLINE (com o Windows aberto): roda DISM /RestoreHealth (conserta a imagem do sistema, a "fonte" que o SFC usa) e depois SFC /scannow (conserta arquivos protegidos do Windows), le e resume o SrtTrail.txt (o log da tela "nao foi possivel reparar"), e SALVA um arquivo .log no Desktop com o RESULTADO DO SFC na primeira linha e o que ainda falta fazer. Nao roda bootrec/bcdboot (esses so funcionam no WinRE) - mas o log te diz se precisa ir pra la. Envie o .log gerado se precisar de ajuda.'},

    # === SEGURANCA ===
    @{Id='rastreador'; Name='Rastreador de acessos remotos'; Cat='SEGURANCA'; Desc='So leitura, nao altera e nao remove nada. Procura QUEM pode entrar nesta maquina de fora: programas de acesso remoto e RMM (AnyDesk, TeamViewer, ScreenConnect, Atera, RustDesk, Action1 e ~25 outros), servico ou tarefa agendada rodando de lugar incomum, AnyDesk com senha fixa (entra sem ninguem aceitar) e RDP habilitado. Confere QUEM ASSINOU cada binario - "alterado depois de assinado" nunca e normal. Fala PT/ES/EN conforme o Windows. Gera um TXT no Desktop pronto pra ler OU pra colar em qualquer IA (o arquivo traz as instrucoes e um bloco JSON dentro). Abre em janela propria. Roda direto do repo formatei-pc (GCintra00).'},

    # === INTERNET/WIFI ===
    @{Id='netdiag'; Name='Diagnostico de conexao (WiFi + ping)'; Cat='INTERNET/WIFI'; Desc='So leitura, nao muda nada. Mede sinal WiFi, banda e taxa, e faz ping no roteador e na internet pra dizer DE QUEM e a lentidao: do seu PC/WiFi, do roteador ou do provedor. Resumo no topo, detalhes embaixo.'},
    @{Id='netopt'; Name='Otimizar rede (placa WiFi + DNS)'; Cat='INTERNET/WIFI'; Desc='Aplica ajustes SEGUROS do lado do PC: desliga a economia de energia da placa WiFi (causa lentidao/quedas) e limpa o cache DNS. Opcional: definir DNS rapido (8.8.8.8/1.1.1.1) - NAO use em PC corporativo com DNS interno. Nao mexe em TCP/winsock (mito/arriscado).'}
)

# ============= UI =============
$script:form = New-Object System.Windows.Forms.Form
$form.Text = "Disk Toolkit - Manutencao de Disco"
$form.Size = New-Object System.Drawing.Size(820, 560)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# --- TreeView esquerda ---
$tree = New-Object System.Windows.Forms.TreeView
$tree.Location = New-Object System.Drawing.Point(10, 10)
$tree.Size = New-Object System.Drawing.Size(280, 470)
$tree.HideSelection = $false
$tree.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$catNodes = @{}
foreach ($a in $actions) {
    if (-not $catNodes.ContainsKey($a.Cat)) {
        $catNode = $tree.Nodes.Add($a.Cat, $a.Cat)
        $catNode.NodeFont = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $catNodes[$a.Cat] = $catNode
    }
    $node = $catNodes[$a.Cat].Nodes.Add($a.Id, $a.Name)
    $node.Tag = $a.Id
}
$tree.ExpandAll()
$form.Controls.Add($tree)

# --- Painel direita: descricao + parametros + botao ---

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point(310, 10)
$lblTitle.Size = New-Object System.Drawing.Size(480, 24)
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$lblTitle.Text = "Selecione uma acao na esquerda"
$form.Controls.Add($lblTitle)

$lblDesc = New-Object System.Windows.Forms.Label
$lblDesc.Location = New-Object System.Drawing.Point(310, 38)
$lblDesc.Size = New-Object System.Drawing.Size(480, 100)
$lblDesc.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblDesc.Text = ""
$form.Controls.Add($lblDesc)

# Painel onde campos contextuais aparecem
$paramPanel = New-Object System.Windows.Forms.Panel
$paramPanel.Location = New-Object System.Drawing.Point(310, 145)
$paramPanel.Size = New-Object System.Drawing.Size(480, 280)
$paramPanel.BorderStyle = "FixedSingle"
$form.Controls.Add($paramPanel)

$btnExecute = New-Object System.Windows.Forms.Button
$btnExecute.Text = "Executar Acao"
$btnExecute.Location = New-Object System.Drawing.Point(610, 440)
$btnExecute.Size = New-Object System.Drawing.Size(180, 40)
$btnExecute.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnExecute.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnExecute.ForeColor = [System.Drawing.Color]::White
$btnExecute.Enabled = $false
$form.Controls.Add($btnExecute)

$script:statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(10, 495)
$statusLabel.Size = New-Object System.Drawing.Size(780, 22)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($statusLabel)

# ============= Builders de painel contextual =============

function Clear-ParamPanel { $paramPanel.Controls.Clear() }

function Add-Label($x, $y, $w, $h, $text, $bold=$false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Text = $text
    if ($bold) { $l.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold) }
    $paramPanel.Controls.Add($l)
    return $l
}

function Add-Combo($x, $y, $w, $items, $displayMember='Display') {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 22)
    $c.DropDownStyle = "DropDownList"
    $c.DisplayMember = $displayMember
    foreach ($i in $items) { $c.Items.Add($i) | Out-Null }
    if ($c.Items.Count -gt 0) { $c.SelectedIndex = 0 }
    $paramPanel.Controls.Add($c)
    return $c
}

function Add-Textbox($x, $y, $w, $default='') {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, 22)
    $t.Text = $default
    $paramPanel.Controls.Add($t)
    return $t
}

function Add-Checkbox($x, $y, $w, $text, $checked=$false) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 22)
    $c.Text = $text
    $c.Checked = $checked
    $paramPanel.Controls.Add($c)
    return $c
}

function Add-Multiline($x, $y, $w, $h) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, $h)
    $t.Multiline = $true
    $t.ScrollBars = "Vertical"
    $t.ReadOnly = $true
    $t.Font = New-Object System.Drawing.Font("Consolas", 9)
    $paramPanel.Controls.Add($t)
    return $t
}

# ============= Painel contextual por acao =============

$script:ctx = @{}  # guarda referencias dos controles do painel atual

function Build-Panel($actionId) {
    Clear-ParamPanel
    $script:ctx = @{}

    switch ($actionId) {
        'helpcmds' {
            Add-Label 10 10 460 22 "Scripts disponiveis (escolha aba, clica num script, use botoes):" $true

            # === Listas de comandos por conta ===
            $script:helpCmdsGC = @(
                @{Name='Setup PC Pessoal'; Desc='8 etapas: bloatware + programas + config'; Cmd='Get-NetAdapter | Where Status -eq Up | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4") }; irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/setup.ps1 | iex'},
                @{Name='Setup Light'; Desc='so Chrome + limpezas (mais rapido)'; Cmd='Get-NetAdapter | Where Status -eq Up | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4") }; irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/setup-light.ps1 | iex'},
                @{Name='Disk Toolkit'; Desc='esta ferramenta (re-executar)'; Cmd='irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/disk-toolkit.ps1 | iex'},
                @{Name='Preparar HDD Storage'; Desc='wipe + format NTFS focado'; Cmd='irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/prepare-storage.ps1 | iex'},
                @{Name='Limpeza do Sistema'; Desc='cache, cookies, temp'; Cmd='irm https://raw.githubusercontent.com/GCintra00/limpeza/master/limpeza.ps1 | iex'},
                @{Name='UTI do Windows v6'; Desc='PC travado: mata apps + startup + DISM/SFC + disco (respirando por maquinas)'; Cmd='irm https://raw.githubusercontent.com/GCintra00/limpeza/master/uti-v6.ps1 | iex'},
                @{Name='Calor e bateria (termico)'; Desc='temperatura cruzada com a carga, throttling, evento de firmware, desligamento sujo, saude da bateria'; Cmd='irm https://raw.githubusercontent.com/GCintra00/limpeza/master/termico.ps1 | iex'},
                @{Name='Energia / clock da CPU'; Desc='PC lento a 0,4 GHz: mede ocioso e sob carga, libera a energia (teto/piso, turbo, economia, slider) e mede de novo'; Cmd='irm https://raw.githubusercontent.com/GCintra00/limpeza/master/energia.ps1 | iex'},
                @{Name='Rastreador de acessos remotos'; Desc='quem pode entrar de fora: RMM/acesso remoto + assinatura + RDP; TXT no Desktop pronto pra IA'; Cmd='irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/rastreador-acessos-remotos.ps1 | iex'},
                                @{Name='Corrigir DNS (Google 8.8.8.8)'; Desc='resolve DNS quebrado em PCs recem-formatados'; Cmd='Get-NetAdapter | Where Status -eq Up | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4") }'},
                @{Name='Serial Number do PC'; Desc='mostra serial da BIOS (pra registro)'; Cmd='(Get-CimInstance Win32_BIOS).SerialNumber'},
                @{Name='IP LAN da maquina'; Desc='mostra IP local'; Cmd='(Get-NetIPAddress -AddressFamily IPv4 | Where { $_.PrefixOrigin -in "Dhcp","Manual" -and $_.IPAddress -notlike "169.*" -and $_.IPAddress -notlike "127.*" } | Select -First 1).IPAddress'},
                @{Name='Listar usuarios locais'; Desc='nome, nome completo, ultimo login'; Cmd='Get-LocalUser | Where Enabled | Format-Table Name, FullName, LastLogon'},
                @{Name='Listar compartilhamentos SMB'; Desc='shares ativos (sem os do sistema)'; Cmd='Get-SmbShare | Where { -not $_.Special }'}
            )
            $script:helpCmdsIGN = @(
                @{Name='Setup PC Empresa'; Desc='setup corporativo IG Networks (13 etapas)'; Cmd='Get-NetAdapter | Where Status -eq Up | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4") }; irm https://raw.githubusercontent.com/igcintra/pc-setup/master/setup.ps1 | iex'},
                @{Name='Verificacao de seguranca (Action1)'; Desc='mesmo rastreador, versao da empresa - o nome do arquivo casa com o tutorial do accounting'; Cmd='irm https://raw.githubusercontent.com/igcintra/pc-setup/master/verificar-action1.ps1 | iex'},
                                @{Name='Diagnostico de Audio'; Desc='coleta endpoints/drivers/mic/fone - copia pro clipboard'; Cmd='irm https://raw.githubusercontent.com/igcintra/pc-setup/master/diag-audio.ps1 | iex'}
            )

            # === TabControl com 2 abas ===
            $tabs = New-Object System.Windows.Forms.TabControl
            $tabs.Location = New-Object System.Drawing.Point(10, 35)
            $tabs.Size = New-Object System.Drawing.Size(460, 145)
            $script:ctx.helpTabs = $tabs

            # Aba 1: GCintra00 (pessoal)
            $tabGC = New-Object System.Windows.Forms.TabPage
            $tabGC.Text = "GCintra00 (pessoal)"
            $listGC = New-Object System.Windows.Forms.ListView
            $listGC.Dock = "Fill"
            $listGC.View = "Details"
            $listGC.FullRowSelect = $true
            $listGC.GridLines = $true
            $listGC.MultiSelect = $false
            $listGC.Columns.Add("Script", 190) | Out-Null
            $listGC.Columns.Add("O que faz", 245) | Out-Null
            for ($i = 0; $i -lt $script:helpCmdsGC.Count; $i++) {
                $c = $script:helpCmdsGC[$i]
                $item = New-Object System.Windows.Forms.ListViewItem($c.Name)
                $item.SubItems.Add($c.Desc) | Out-Null
                $item.Tag = $i
                $listGC.Items.Add($item) | Out-Null
            }
            $listGC.Add_SelectedIndexChanged({
                if ($listGC.SelectedItems.Count -gt 0) {
                    $idx = $listGC.SelectedItems[0].Tag
                    $script:ctx.helpPreview.Text = $script:helpCmdsGC[$idx].Cmd
                }
            }.GetNewClosure())
            $tabGC.Controls.Add($listGC)
            $tabs.TabPages.Add($tabGC)
            $script:ctx.helpListGC = $listGC

            # Aba 2: IGN (empresa)
            $tabIGN = New-Object System.Windows.Forms.TabPage
            $tabIGN.Text = "IGN (empresa)"
            $listIGN = New-Object System.Windows.Forms.ListView
            $listIGN.Dock = "Fill"
            $listIGN.View = "Details"
            $listIGN.FullRowSelect = $true
            $listIGN.GridLines = $true
            $listIGN.MultiSelect = $false
            $listIGN.Columns.Add("Script", 190) | Out-Null
            $listIGN.Columns.Add("O que faz", 245) | Out-Null
            for ($i = 0; $i -lt $script:helpCmdsIGN.Count; $i++) {
                $c = $script:helpCmdsIGN[$i]
                $item = New-Object System.Windows.Forms.ListViewItem($c.Name)
                $item.SubItems.Add($c.Desc) | Out-Null
                $item.Tag = $i
                $listIGN.Items.Add($item) | Out-Null
            }
            $listIGN.Add_SelectedIndexChanged({
                if ($listIGN.SelectedItems.Count -gt 0) {
                    $idx = $listIGN.SelectedItems[0].Tag
                    $script:ctx.helpPreview.Text = $script:helpCmdsIGN[$idx].Cmd
                }
            }.GetNewClosure())
            $tabIGN.Controls.Add($listIGN)
            $tabs.TabPages.Add($tabIGN)
            $script:ctx.helpListIGN = $listIGN

            $paramPanel.Controls.Add($tabs)

            # Preview do comando selecionado (compartilhado entre as 2 abas)
            Add-Label 10 185 460 22 "Comando:" $true
            $script:ctx.helpPreview = New-Object System.Windows.Forms.TextBox
            $script:ctx.helpPreview.Location = New-Object System.Drawing.Point(10, 207)
            $script:ctx.helpPreview.Size = New-Object System.Drawing.Size(460, 35)
            $script:ctx.helpPreview.Multiline = $true
            $script:ctx.helpPreview.ReadOnly = $true
            $script:ctx.helpPreview.ScrollBars = "Vertical"
            $script:ctx.helpPreview.Font = New-Object System.Drawing.Font("Consolas", 8)
            $paramPanel.Controls.Add($script:ctx.helpPreview)

            # Botoes contextuais
            $btnRun = New-Object System.Windows.Forms.Button
            $btnRun.Text = "Rodar (nova janela)"
            $btnRun.Location = New-Object System.Drawing.Point(10, 248)
            $btnRun.Size = New-Object System.Drawing.Size(150, 28)
            $btnRun.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
            $btnRun.ForeColor = [System.Drawing.Color]::White
            $btnRun.Add_Click({ Invoke-HelpCommand })
            $paramPanel.Controls.Add($btnRun)

            $btnCopy = New-Object System.Windows.Forms.Button
            $btnCopy.Text = "Copiar pro clipboard"
            $btnCopy.Location = New-Object System.Drawing.Point(170, 248)
            $btnCopy.Size = New-Object System.Drawing.Size(150, 28)
            $btnCopy.Add_Click({
                $cmd = Get-HelpCommand
                if (-not $cmd) { Show-Msg "Selecione um script de uma das abas." 'Aviso' 'Warning'; return }
                Set-Clipboard -Value $cmd
                Set-Status "Comando copiado pro clipboard" ([System.Drawing.Color]::DarkGreen)
            })
            $paramPanel.Controls.Add($btnCopy)
        }
        'smart' {
            Add-Label 10 10 200 22 "Selecione o disco:" $true
            $script:ctx.disk = Add-Combo 10 35 460 (Get-DiskDropdownItems $true)
            $script:ctx.output = Add-Multiline 10 70 460 200
        }
        'info' {
            Add-Label 10 10 200 22 "Selecione o disco:" $true
            $script:ctx.disk = Add-Combo 10 35 460 (Get-DiskDropdownItems $true)
            $script:ctx.output = Add-Multiline 10 70 460 200
        }
        'wipe' {
            Add-Label 10 10 460 22 "Selecione o disco (sistema oculto - bloqueado):" $true
            $script:ctx.disk = Add-Combo 10 35 460 (Get-DiskDropdownItems $false)
            Add-Label 10 68 200 22 "Label do novo volume:" $true
            $script:ctx.label = Add-Textbox 10 92 200 "HDD"
            $script:ctx.secure = Add-Checkbox 10 122 460 "Formatacao SEGURA (zera setores - SO HD, MUITO LENTO)" $false
            Add-Label 10 150 460 100 "ATENCAO: apaga TUDO no disco, sem desfazer.`n`nFormatacao segura zera todos os setores (irrecuperavel) - SO funciona em HD.`nEm SSD/NVMe nao garante e sera bloqueada (use secure erase do fabricante).`nZerar um HD grande pode levar HORAS."
        }
        'label' {
            Add-Label 10 10 200 22 "Selecione o volume:" $true
            $script:ctx.vol = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 70 200 22 "Nova label:" $true
            $script:ctx.label = Add-Textbox 10 95 200
        }
        'letter' {
            Add-Label 10 10 200 22 "Selecione o volume:" $true
            $script:ctx.vol = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 70 200 22 "Nova letra (A-Z):" $true
            $script:ctx.newletter = Add-Textbox 10 95 60
        }
        'resize' {
            Add-Label 10 10 200 22 "Selecione o volume:" $true
            $script:ctx.vol = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 70 460 22 "Novo tamanho em GB (vazio = maximo possivel):" $true
            $script:ctx.newsize = Add-Textbox 10 95 100
            Add-Label 10 130 460 60 "Diminuir requer espaco livre dentro do volume.`nAumentar requer espaco nao alocado adjacente."
        }
        'format' {
            Add-Label 10 10 200 22 "Selecione o volume:" $true
            $script:ctx.vol = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 70 200 22 "Sistema de arquivos:" $true
            $script:ctx.fs = New-Object System.Windows.Forms.ComboBox
            $script:ctx.fs.Location = New-Object System.Drawing.Point(10, 95)
            $script:ctx.fs.Size = New-Object System.Drawing.Size(120, 22)
            $script:ctx.fs.DropDownStyle = "DropDownList"
            "NTFS","exFAT","FAT32","ReFS" | ForEach-Object { $script:ctx.fs.Items.Add($_) | Out-Null }
            $script:ctx.fs.SelectedIndex = 0
            $paramPanel.Controls.Add($script:ctx.fs)
            Add-Label 10 130 200 22 "Label:" $true
            $script:ctx.label = Add-Textbox 10 155 200
            Add-Label 10 195 460 30 "ATENCAO: apaga todos os dados da particao."
        }
        'chkdsk' {
            Add-Label 10 8 200 22 "Selecione o volume:" $true
            $script:ctx.vol = Add-Combo 10 32 460 (Get-VolumeDropdownItems)
            $script:ctx.online = Add-Checkbox 10 60 460 "Verificacao online rapida (/scan - nao precisa reboot)" $true
            $script:ctx.fix    = Add-Checkbox 10 82 460 "Corrigir erros (/f - agenda no boot se em uso)" $false
            $script:ctx.scan   = Add-Checkbox 10 104 460 "Varredura de setores defeituosos (/r - MUITO LENTO)" $false

            $btnSched = New-Object System.Windows.Forms.Button
            $btnSched.Text = "Ver agendamento"
            $btnSched.Location = New-Object System.Drawing.Point(10, 132)
            $btnSched.Size = New-Object System.Drawing.Size(150, 26)
            $btnSched.Add_Click({ Show-ChkdskSchedule })
            $paramPanel.Controls.Add($btnSched)

            $btnCancelSched = New-Object System.Windows.Forms.Button
            $btnCancelSched.Text = "Cancelar agendamento"
            $btnCancelSched.Location = New-Object System.Drawing.Point(170, 132)
            $btnCancelSched.Size = New-Object System.Drawing.Size(160, 26)
            $btnCancelSched.Add_Click({ Cancel-ChkdskSchedule })
            $paramPanel.Controls.Add($btnCancelSched)

            $script:ctx.output = Add-Multiline 10 164 460 106
        }
        'repairboot' {
            Add-Label 10 8 460 40 "Reparo ONLINE: DISM (repara a imagem) + SFC (repara arquivos), le o SrtTrail e salva um .log no Desktop pra voce enviar." $true
            $script:ctx.dism = Add-Checkbox 10 52 460 "Rodar DISM RestoreHealth (repara a imagem - precisa internet)" $true
            $script:ctx.sfc  = Add-Checkbox 10 74 460 "Rodar SFC /scannow (repara arquivos do sistema)" $true
            $script:ctx.srt  = Add-Checkbox 10 96 460 "Ler e resumir o SrtTrail.txt (causa da tela azul)" $true
            Add-Label 10 120 460 26 "Pode levar varios minutos. A janela pode parecer travada enquanto roda - e normal."

            $btnOpenLog = New-Object System.Windows.Forms.Button
            $btnOpenLog.Text = "Abrir pasta do log"
            $btnOpenLog.Location = New-Object System.Drawing.Point(10, 148)
            $btnOpenLog.Size = New-Object System.Drawing.Size(160, 26)
            $btnOpenLog.Add_Click({
                if ($script:lastRepairLog -and (Test-Path $script:lastRepairLog)) {
                    Start-Process explorer.exe -ArgumentList "/select,`"$($script:lastRepairLog)`""
                } else {
                    Show-Msg "Rode o reparo primeiro - o log ainda nao foi gerado." "Log" "Information"
                }
            })
            $paramPanel.Controls.Add($btnOpenLog)

            $script:ctx.output = Add-Multiline 10 180 460 90
        }
        'defrag' {
            Add-Label 10 10 200 22 "Selecione o volume:" $true
            $script:ctx.vol = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 70 460 40 "Sera detectado automaticamente se eh HDD ou SSD e aplicada a operacao correta."
            $script:ctx.output = Add-Multiline 10 115 460 155
        }
        'wipefree' {
            Add-Label 10 10 200 22 "Selecione o volume:" $true
            $script:ctx.vol = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 70 460 60 "Sobrescreve TODO o espaco livre com zeros.`nPode demorar bastante (depende do tamanho do disco)."
            $script:ctx.output = Add-Multiline 10 135 460 135
        }
        'backupuser' {
            Add-Label 10 10 200 22 "Destino (para onde copiar):" $true
            $script:ctx.dest = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 65 460 22 "Perfis encontrados em C:\Users :" $true

            $script:ctx.profiles = New-Object System.Windows.Forms.CheckedListBox
            $script:ctx.profiles.Location = New-Object System.Drawing.Point(10, 90)
            $script:ctx.profiles.Size = New-Object System.Drawing.Size(220, 175)
            $script:ctx.profiles.CheckOnClick = $true
            foreach ($p in (Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
                if ($p.Name -notin @('Default','Default User','All Users','Public','desktop.ini')) {
                    $script:ctx.profiles.Items.Add($p.Name) | Out-Null
                }
            }
            $paramPanel.Controls.Add($script:ctx.profiles)

            Add-Label 240 65 230 22 "Pastas a copiar:" $true
            $script:ctx.fDesktop  = Add-Checkbox 240 90  230 "Desktop" $true
            $script:ctx.fDocs     = Add-Checkbox 240 110 230 "Documentos" $true
            $script:ctx.fPics     = Add-Checkbox 240 130 230 "Imagens" $true
            $script:ctx.fVids     = Add-Checkbox 240 150 230 "Videos" $true
            $script:ctx.fMusic    = Add-Checkbox 240 170 230 "Musica" $true
            $script:ctx.fDown     = Add-Checkbox 240 190 230 "Downloads" $false
            $script:ctx.fAppData  = Add-Checkbox 240 210 230 "AppData (configs de apps)" $false
            $script:ctx.fFavs     = Add-Checkbox 240 230 230 "Favoritos (browsers)" $false
        }
        'clonedados' {
            Add-Label 10 10 200 22 "Volume origem:" $true
            $script:ctx.src = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 70 200 22 "Volume destino:" $true
            $script:ctx.dst = Add-Combo 10 95 460 (Get-VolumeDropdownItems)
            $script:ctx.mirror = Add-Checkbox 10 130 460 "Modo espelho (/MIR - apaga no destino o que nao existir na origem)" $false
            Add-Label 10 170 460 80 "Usa robocopy multi-thread (/MT:8).`nNAO funciona para clonar C: (Windows bloqueia).`nUse para discos de dados secundarios (D:, E:, etc)."
        }
        'vhdx' {
            Add-Label 10 10 460 22 "Destino (onde salvar o arquivo .vhdx):" $true
            $script:ctx.dst = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            Add-Label 10 70 460 60 "Sera criado um arquivo VHDX no destino contendo`numa copia do C: tirada a quente via VSS."
            Add-Label 10 140 460 22 "Tamanho aproximado esperado:" $true
            try {
                $usedC = (Get-Volume -DriveLetter C).Size - (Get-Volume -DriveLetter C).SizeRemaining
                Add-Label 10 165 460 22 "$(Format-Bytes $usedC) (espaco usado no C:)"
            } catch {}
            Add-Label 10 200 460 50 "Requer ter o Disk2VHD.exe da Sysinternals.`nO script tenta baixar se nao existir."
        }
        'share' {
            Add-Label 10 10 200 22 "Pasta a compartilhar:" $true
            $script:ctx.folderPath = Add-Textbox 10 35 380
            $btnBrowse = New-Object System.Windows.Forms.Button
            $btnBrowse.Location = New-Object System.Drawing.Point(395, 33)
            $btnBrowse.Size = New-Object System.Drawing.Size(75, 26)
            $btnBrowse.Text = "Procurar..."
            $btnBrowse.Add_Click({
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = "Escolha a pasta para compartilhar na rede"
                if ($dlg.ShowDialog() -eq 'OK') {
                    $script:ctx.folderPath.Text = $dlg.SelectedPath
                    if (-not $script:ctx.shareName.Text) {
                        $script:ctx.shareName.Text = (Split-Path $dlg.SelectedPath -Leaf) -replace '\s+',''
                    }
                }
            })
            $paramPanel.Controls.Add($btnBrowse)

            Add-Label 10 70 200 22 "Nome do compartilhamento:" $true
            $script:ctx.shareName = Add-Textbox 10 95 230
            Add-Label 245 70 220 22 "(sem caracteres especiais)" $false

            Add-Label 10 130 460 22 "Usuario de acesso:" $true

            # Radio 1: Usuario existente (dropdown + senha)
            $script:ctx.rbExisting = New-Object System.Windows.Forms.RadioButton
            $script:ctx.rbExisting.Text = "Usuario existente"
            $script:ctx.rbExisting.Location = New-Object System.Drawing.Point(10, 155)
            $script:ctx.rbExisting.Size = New-Object System.Drawing.Size(140, 22)
            $script:ctx.rbExisting.Checked = $true
            $paramPanel.Controls.Add($script:ctx.rbExisting)

            $script:ctx.cmbExisting = New-Object System.Windows.Forms.ComboBox
            $script:ctx.cmbExisting.Location = New-Object System.Drawing.Point(160, 155)
            $script:ctx.cmbExisting.Size = New-Object System.Drawing.Size(165, 22)
            $script:ctx.cmbExisting.DropDownStyle = "DropDownList"
            foreach ($u in (Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.Enabled })) {
                $script:ctx.cmbExisting.Items.Add($u.Name) | Out-Null
            }
            if ($script:ctx.cmbExisting.Items.Count -gt 0) { $script:ctx.cmbExisting.SelectedIndex = 0 }
            $paramPanel.Controls.Add($script:ctx.cmbExisting)

            Add-Label 335 155 50 22 "Senha:" $false
            $script:ctx.pwdExisting = Add-Textbox 385 155 85
            $script:ctx.pwdExisting.UseSystemPasswordChar = $true

            # Radio 2: Criar novo (textbox + senha)
            $script:ctx.rbNew = New-Object System.Windows.Forms.RadioButton
            $script:ctx.rbNew.Text = "Criar novo"
            $script:ctx.rbNew.Location = New-Object System.Drawing.Point(10, 185)
            $script:ctx.rbNew.Size = New-Object System.Drawing.Size(140, 22)
            $paramPanel.Controls.Add($script:ctx.rbNew)

            $script:ctx.txtNew = Add-Textbox 160 185 165
            Add-Label 335 185 50 22 "Senha:" $false
            $script:ctx.pwdNew = Add-Textbox 385 185 85
            $script:ctx.pwdNew.UseSystemPasswordChar = $true

            $script:ctx.shareFull = Add-Checkbox 10 220 460 "Permitir escrita (desmarcado = somente leitura)" $true
        }
        'listshares' {
            Add-Label 10 10 460 22 "Compartilhamentos ativos (selecione para remover):" $true
            $script:ctx.sharesList = New-Object System.Windows.Forms.ListView
            $script:ctx.sharesList.Location = New-Object System.Drawing.Point(10, 35)
            $script:ctx.sharesList.Size = New-Object System.Drawing.Size(460, 200)
            $script:ctx.sharesList.View = "Details"
            $script:ctx.sharesList.FullRowSelect = $true
            $script:ctx.sharesList.GridLines = $true
            $script:ctx.sharesList.Columns.Add("Nome", 130) | Out-Null
            $script:ctx.sharesList.Columns.Add("Caminho local", 230) | Out-Null
            $script:ctx.sharesList.Columns.Add("Tipo", 80) | Out-Null
            Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { -not $_.Special } | ForEach-Object {
                $item = New-Object System.Windows.Forms.ListViewItem($_.Name)
                $item.SubItems.Add($_.Path) | Out-Null
                $item.SubItems.Add($_.ShareType.ToString()) | Out-Null
                $script:ctx.sharesList.Items.Add($item) | Out-Null
            }
            $paramPanel.Controls.Add($script:ctx.sharesList)
            Add-Label 10 240 460 30 "Clique em Executar para remover o compartilhamento selecionado."
        }
        'createuser' {
            Add-Label 10 10 200 22 "Nome do usuario:" $true
            $script:ctx.username = Add-Textbox 10 35 280
            Add-Label 10 70 200 22 "Senha:" $true
            $script:ctx.password = Add-Textbox 10 95 280
            $script:ctx.password.UseSystemPasswordChar = $true
            Add-Label 10 130 200 22 "Nome completo (opcional):" $true
            $script:ctx.fullname = Add-Textbox 10 155 280
            $script:ctx.admin = Add-Checkbox 10 190 460 "Tornar Administrador (recomendado pra conta tecnica)" $true
            $script:ctx.noexpire = Add-Checkbox 10 215 460 "Senha nunca expira" $true
            Add-Label 10 245 460 30 "Conta sera criada como LOCAL (sem vinculo com conta Microsoft)."
        }
        'users' {
            Add-Label 10 10 460 22 "Perfis locais do Windows:" $true
            $script:ctx.profiles = New-Object System.Windows.Forms.ListView
            $script:ctx.profiles.Location = New-Object System.Drawing.Point(10, 35)
            $script:ctx.profiles.Size = New-Object System.Drawing.Size(460, 200)
            $script:ctx.profiles.View = "Details"
            $script:ctx.profiles.FullRowSelect = $true
            $script:ctx.profiles.GridLines = $true
            $script:ctx.profiles.Columns.Add("Usuario", 130) | Out-Null
            $script:ctx.profiles.Columns.Add("Tamanho", 90) | Out-Null
            $script:ctx.profiles.Columns.Add("Ultimo uso", 110) | Out-Null
            $script:ctx.profiles.Columns.Add("Status", 110) | Out-Null

            Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | ForEach-Object {
                $name = Split-Path $_.LocalPath -Leaf
                $size = ""
                try {
                    if (Test-Path $_.LocalPath) {
                        $bytes = (Get-ChildItem $_.LocalPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                        if ($bytes) { $size = Format-Bytes $bytes }
                    }
                } catch {}
                $lastUse = if ($_.LastUseTime) { ([Management.ManagementDateTimeConverter]::ToDateTime($_.LastUseTime)).ToString("yyyy-MM-dd") } else { "n/a" }
                $status = if ($_.Loaded) { "EM USO" } else { "Disponivel" }

                $item = New-Object System.Windows.Forms.ListViewItem($name)
                $item.SubItems.Add($size) | Out-Null
                $item.SubItems.Add($lastUse) | Out-Null
                $item.SubItems.Add($status) | Out-Null
                $item.Tag = $_.LocalPath
                if ($_.Loaded) { $item.ForeColor = [System.Drawing.Color]::Gray }
                $script:ctx.profiles.Items.Add($item) | Out-Null
            }
            $paramPanel.Controls.Add($script:ctx.profiles)
            Add-Label 10 240 460 30 "Selecione um perfil e clique Executar pra apagar."
        }
        'renameuser' {
            Add-Label 10 6 460 20 "Perfis locais do Windows:" $true
            $script:ctx.profiles = New-Object System.Windows.Forms.ListView
            $script:ctx.profiles.Location = New-Object System.Drawing.Point(10, 28)
            $script:ctx.profiles.Size = New-Object System.Drawing.Size(460, 124)
            $script:ctx.profiles.View = "Details"
            $script:ctx.profiles.FullRowSelect = $true
            $script:ctx.profiles.GridLines = $true
            $script:ctx.profiles.Columns.Add("Pasta atual", 120) | Out-Null
            $script:ctx.profiles.Columns.Add("Conta", 105) | Out-Null
            $script:ctx.profiles.Columns.Add("Tamanho", 78) | Out-Null
            $script:ctx.profiles.Columns.Add("Status", 132) | Out-Null

            Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special } | ForEach-Object {
                $regSid  = $_.SID
                $regPath = $_.LocalPath
                $folder  = Split-Path $regPath -Leaf
                $onDisk  = Test-Path $regPath

                # Conta local dona do SID (pode nao existir: perfil de conta ja apagada / de dominio)
                $account = ""
                try {
                    $account = (Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -eq $regSid } | Select-Object -First 1).Name
                } catch {}

                $size = ""
                try {
                    if ($onDisk) {
                        $bytes = (Get-ChildItem $regPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                        if ($bytes) { $size = Format-Bytes $bytes }
                    }
                } catch {}

                $status = if (-not $onDisk) { "INCONSISTENTE" } elseif ($_.Loaded) { "EM USO" } else { "Disponivel" }

                $item = New-Object System.Windows.Forms.ListViewItem($folder)
                $item.SubItems.Add($account) | Out-Null
                $item.SubItems.Add($size) | Out-Null
                $item.SubItems.Add($status) | Out-Null
                $item.Tag = [PSCustomObject]@{
                    Sid     = $regSid
                    RegPath = $regPath
                    OnDisk  = $onDisk
                    Loaded  = [bool]$_.Loaded
                    Account = $account
                }
                if ($_.Loaded)  { $item.ForeColor = [System.Drawing.Color]::Gray }
                if (-not $onDisk) { $item.ForeColor = [System.Drawing.Color]::Firebrick }
                $script:ctx.profiles.Items.Add($item) | Out-Null
            }
            $paramPanel.Controls.Add($script:ctx.profiles)

            Add-Label 10 158 200 20 "Novo nome da pasta:" $true
            $script:ctx.newname = Add-Textbox 10 178 190
            $script:ctx.alsoAccount = Add-Checkbox 212 178 258 "Renomear tambem a conta local" $true
            $script:ctx.junction = Add-Checkbox 10 202 460 "Criar atalho (junction) com o nome antigo - PC ja em uso" $false
            Add-Label 10 226 460 44 "Rode por OUTRA conta admin, com o perfil alvo deslogado. REINICIE antes de logar no perfil renomeado. Linha vermelha = registro aponta pra pasta que nao existe."
        }
        'overview' {
            Add-Label 10 10 460 22 "Todos os discos (clique Executar pra atualizar):" $true
            $script:ctx.overviewList = New-Object System.Windows.Forms.ListView
            $script:ctx.overviewList.Location = New-Object System.Drawing.Point(10, 35)
            $script:ctx.overviewList.Size = New-Object System.Drawing.Size(460, 235)
            $script:ctx.overviewList.View = "Details"
            $script:ctx.overviewList.FullRowSelect = $true
            $script:ctx.overviewList.GridLines = $true
            $script:ctx.overviewList.Font = New-Object System.Drawing.Font("Consolas", 8)
            $script:ctx.overviewList.Columns.Add("Disk", 36) | Out-Null
            $script:ctx.overviewList.Columns.Add("Modelo", 135) | Out-Null
            $script:ctx.overviewList.Columns.Add("Tipo", 48) | Out-Null
            $script:ctx.overviewList.Columns.Add("Saude", 50) | Out-Null
            $script:ctx.overviewList.Columns.Add("Vida util", 125) | Out-Null
            $script:ctx.overviewList.Columns.Add("Letras", 58) | Out-Null
            $paramPanel.Controls.Add($script:ctx.overviewList)
            Populate-Overview
        }
        'activate' {
            Add-Label 10 10 460 42 "Le a chave OEM da placa-mae (firmware/MSDM) e mostra status, tipo de licenca e validade. OEM/Retail = permanente." $false
            $script:ctx.reactivate = Add-Checkbox 10 56 460 "Forcar reativacao (instala a chave OEM e ativa)" $false
            $script:ctx.output = Add-Multiline 10 85 460 185
        }
        'termico' {
            Add-Label 10 8 460 22 "Clique Executar pra medir calor, throttling e bateria (so leitura)." $true
            $script:ctx.batreport = Add-Checkbox 10 32 460 "Gerar relatorio de bateria (HTML no Desktop)" $false
            $script:ctx.termLog = Add-Checkbox 10 56 460 "Salvar log no Desktop" $true
            $script:ctx.output = Add-Multiline 10 82 460 188
        }
        'energia' {
            Add-Label 10 8 460 32 "Mede o clock ocioso e SOB CARGA (o PC fica lento uns 25 s), libera a energia e mede de novo." $true
            $script:ctx.enFix = Add-Checkbox 10 44 460 "Liberar a energia (teto/piso, turbo, economia, slider) - desmarque p/ so medir" $true
            $script:ctx.enLog = Add-Checkbox 10 67 460 "Salvar log no Desktop" $true
            $script:ctx.output = Add-Multiline 10 94 460 176
        }
        'checkup' {
            Add-Label 10 8 460 32 "Grava a linha de base e compara com a rodada anterior. Rode ANTES e DEPOIS de mexer na maquina." $true
            $script:ctx.ckLog = Add-Checkbox 10 44 460 "Salvar log no Desktop" $true
            $script:ctx.output = Add-Multiline 10 70 460 200
        }
        'aer' {
            Add-Label 10 8 460 32 "Clique Executar pra contar os WHEA, ver o ASPM e a profundidade do log (so leitura)." $true
            $script:ctx.aerFix = Add-Checkbox 10 44 460 "Desligar o ASPM do link PCIe (reversivel; precisa REINICIAR pra valer)" $false
            $script:ctx.aerLog = Add-Checkbox 10 67 460 "Salvar log no Desktop" $true
            $script:ctx.output = Add-Multiline 10 94 460 176
        }
        'netdiag' {
            Add-Label 10 8 460 22 "Clique Executar pra diagnosticar a conexao (so leitura)." $true
            $script:ctx.speedtest = Add-Checkbox 10 32 460 "Incluir teste de velocidade (baixa ~20 MB do Cloudflare)" $true
            $script:ctx.output = Add-Multiline 10 58 460 212
        }
        'uti' {
            Add-Label 10 10 460 44 "Abre a UTI do Windows numa janela PowerShell propria (elevada). La dentro ela pergunta o modo: [1] watchdog ou [2] log completo. Log e backups: Desktop\UTI-backup." $false
            $script:ctx.output = Add-Multiline 10 60 460 210
        }
        'rastreador' {
            Add-Label 10 10 460 58 "Abre o rastreador numa janela PowerShell propria. Nao pede admin (com admin ve mais). Ao final salva um TXT no Desktop: acessos-remotos-USUARIO-PC-data.txt - da pra ler na mao ou colar numa IA, o arquivo ja explica o que ela deve fazer." $false
            $script:ctx.output = Add-Multiline 10 74 460 196
        }
        'netopt' {
            Add-Label 10 8 460 22 "Ajustes seguros (clique Executar pra aplicar os marcados):" $true
            $script:ctx.optPower    = Add-Checkbox 10 34 460 "Desligar economia de energia da placa WiFi" $true
            $script:ctx.optDnsFlush = Add-Checkbox 10 57 460 "Limpar cache DNS" $true
            $script:ctx.optDnsSet   = Add-Checkbox 10 80 460 "Definir DNS rapido 8.8.8.8/1.1.1.1 (NAO em PC corporativo)" $false
            $script:ctx.output = Add-Multiline 10 108 460 162
        }
    }
}

# ============= Executores =============

function Get-HelpSelected {
    # Retorna hashtable @{Name=...; Cmd=...} do item selecionado na aba ativa, ou $null
    if (-not $script:ctx.helpTabs) { return $null }
    $activeTab = $script:ctx.helpTabs.SelectedIndex
    if ($activeTab -eq 0) {
        $list = $script:ctx.helpListGC; $arr = $script:helpCmdsGC
    } else {
        $list = $script:ctx.helpListIGN; $arr = $script:helpCmdsIGN
    }
    if ($list.SelectedItems.Count -eq 0) { return $null }
    $idx = $list.SelectedItems[0].Tag
    return $arr[$idx]
}

function Get-HelpCommand {
    $sel = Get-HelpSelected
    if ($sel) { return $sel.Cmd } else { return $null }
}

function Invoke-HelpCommand {
    $sel = Get-HelpSelected
    if (-not $sel) { Show-Msg "Selecione um script de uma das abas." 'Aviso' 'Warning'; return }
    $cmd = $sel.Cmd
    $name = $sel.Name

    if (-not (Confirm-Action "Rodar '$name' em uma nova janela do PowerShell?`n`nComando:`n$cmd")) { return }

    # Encoda em base64 pra evitar problemas de escape ao passar via -EncodedCommand
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
    $encoded = [Convert]::ToBase64String($bytes)

    try {
        Start-Process powershell.exe -ArgumentList "-NoExit","-EncodedCommand",$encoded -ErrorAction Stop
        Set-Status "'$name' iniciado em nova janela do PowerShell" ([System.Drawing.Color]::DarkGreen)
    } catch {
        Show-Msg "Falha ao iniciar nova janela: $($_.Exception.Message)" 'Erro' 'Error'
    }
}

function Execute-Action($id) {
    Set-Status "Executando..." ([System.Drawing.Color]::DarkOrange)

    try {
        switch ($id) {
            'helpcmds'   { Invoke-HelpCommand }
            'smart'      { Exec-Smart }
            'info'       { Exec-Info }
            'overview'   { Populate-Overview }
            'activate'   { Exec-Activate }
            'termico'    { Exec-Termico }
            'energia'    { Exec-Energia }
            'checkup'    { Exec-Checkup }
            'aer'        { Exec-Aer }
            'netdiag'    { Exec-NetDiag }
            'netopt'     { Exec-NetOpt }
            'wipe'       { Exec-Wipe }
            'label'      { Exec-Label }
            'letter'     { Exec-Letter }
            'resize'     { Exec-Resize }
            'format'     { Exec-Format }
            'chkdsk'     { Exec-Chkdsk }
            'uti'        { Exec-Uti }
            'rastreador' { Exec-Rastreador }
            'repairboot' { Exec-RepairBoot }
            'defrag'     { Exec-Defrag }
            'wipefree'   { Exec-WipeFree }
            'backupuser' { Exec-BackupUser }
            'clonedados' { Exec-CloneData }
            'vhdx'       { Exec-Vhdx }
            'users'      { Exec-DeleteUser }
            'renameuser' { Exec-RenameUser }
            'createuser' { Exec-CreateUser }
            'share'      { Exec-Share }
            'listshares' { Exec-RemoveShare }
        }
    } catch {
        Set-Status "Erro: $($_.Exception.Message)" ([System.Drawing.Color]::DarkRed)
        Show-Msg "Erro durante a operacao:`n`n$($_.Exception.Message)" "Erro" "Error"
    }
}

# --- INFO ---
# smartctl (smartmontools): fonte completa de SMART p/ SATA, NVMe e USB.
# O WMI nativo do Windows e incompleto (NVMe quase vazio), entao preferimos
# o smartctl quando disponivel e caimos pro WMI como fallback.
$script:SMARTCTL_VERSION = '7.4'
$script:smartctlChecked  = $false
$script:smartctlPath     = $null

function Install-SmartCtl {
    # Baixa o instalador NSIS do smartmontools e instala silencioso em LOCALAPPDATA.
    # /S = silencioso, /D = destino (precisa ser o ULTIMO arg e sem aspas - regra do NSIS).
    if (-not (Confirm-Action "smartctl nao encontrado.`n`nBaixar o smartmontools (~3 MB) para leitura completa de SMART (inclui NVMe e SSD)?`n`nSem ele, uso o WMI do Windows (dados limitados).")) { return $null }
    $ver  = $script:SMARTCTL_VERSION
    $file = "smartmontools-$ver-1.win32-setup.exe"
    # Mirror DIRETO: a URL /files/.../download do SF devolve HTML (salvo como .exe ->
    # "arquivo corrompido"). O master.dl?viasf=1 entrega o binario de verdade.
    $url  = "https://master.dl.sourceforge.net/project/smartmontools/smartmontools/$ver/$file`?viasf=1"
    $dest = Join-Path $env:LOCALAPPDATA 'disk-toolkit\smartctl'
    $tmp  = Join-Path $env:TEMP $file
    try {
        Set-Status "Baixando smartctl..." ([System.Drawing.Color]::DarkOrange)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
        # valida: tem que ser um PE (header 'MZ' = 77,90) e nao um HTML de redirect
        $sig = [System.IO.File]::ReadAllBytes($tmp) | Select-Object -First 2
        if ((Get-Item $tmp).Length -lt 200000 -or $sig[0] -ne 77 -or $sig[1] -ne 90) {
            throw "o download nao e um executavel valido (mirror devolveu pagina?). Tente de novo ou baixe manualmente."
        }
        Set-Status "Instalando smartctl..." ([System.Drawing.Color]::DarkOrange)
        Start-Process -FilePath $tmp -ArgumentList "/S","/D=$dest" -Wait -ErrorAction Stop
        $exe = Join-Path $dest 'bin\smartctl.exe'
        if (Test-Path $exe) { return $exe }
    } catch {
        Show-Msg "Nao consegui baixar/instalar o smartctl:`n$($_.Exception.Message)`n`nBaixe manualmente de smartmontools.org e coloque smartctl.exe na pasta do script. Continuo com o WMI." 'smartctl' 'Warning'
    }
    return $null
}

function Get-SmartCtl {
    if ($script:smartctlChecked) { return $script:smartctlPath }
    $script:smartctlChecked = $true
    $found = $null
    $cmd = Get-Command smartctl.exe -ErrorAction SilentlyContinue
    if ($cmd) { $found = $cmd.Source }
    if (-not $found) {
        $cands = @()
        if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot 'smartctl.exe') }
        $cands += (Join-Path $env:LOCALAPPDATA 'disk-toolkit\smartctl\bin\smartctl.exe')
        if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'smartmontools\bin\smartctl.exe') }
        foreach ($c in $cands) { if ($c -and (Test-Path $c)) { $found = $c; break } }
    }
    if (-not $found) { $found = Install-SmartCtl }
    $script:smartctlPath = $found
    return $found
}

function Get-SmartViaCtl($diskNum) {
    $exe = Get-SmartCtl
    if (-not $exe) { return $null }

    $dev    = "\\.\PhysicalDrive$diskNum"
    $letter = [char]([int][char]'a' + $diskNum)
    # smartctl no Windows aceita varias formas; tentamos ate uma trazer dados.
    # /dev/sdX vem 1o: na pratica e o que auto-detecta tipo (ATA/NVMe) nesta build;
    # \\.\PhysicalDriveN as vezes da "Unable to detect device type".
    $tries = @(
        @('-j','-x',"/dev/sd$letter"),
        @('-j','-x','-d','auto',$dev),
        @('-j','-x',$dev),
        @('-j','-x','-d','sat',$dev),
        @('-j','-x','-d','nvme',$dev)
    )
    $hasData = { param($c) [bool]($c.model_name -or $c.nvme_smart_health_information_log -or ($c.ata_smart_attributes -and $c.ata_smart_attributes.table) -or ($c.power_on_time -and $c.power_on_time.hours)) }
    $o = $null
    foreach ($t in $tries) {
        try {
            $txt = & $exe @t 2>$null | Out-String
            if (-not $txt -or -not $txt.Trim()) { continue }
            $cand = $txt | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }
        if (& $hasData $cand) { $o = $cand; break }
        if (-not $o) { $o = $cand }   # guarda o 1o JSON p/ extrair msg de erro
    }
    if (-not $o) { return $null }

    if (-not (& $hasData $o)) {
        # smartctl rodou mas nao leu o disco -> deixa o WMI assumir; guarda o motivo
        $script:lastSmartctlMsg = (($o.smartctl.messages | ForEach-Object { $_.string }) -join '; ')
        return $null
    }

    $r = @{ Source='smartctl'; Model=$o.model_name; Serial=$o.serial_number; Verdict=$null;
            PowerOnHours=$null; Temp=$null; TempMax=$null; Realloc=$null; Pending=$null;
            Uncorr=$null; ReallEvt=$null; ReadErr=$null; WriteErr=$null; Wear=$null; LifeLeft=$null; Note=$null }

    if ($o.power_on_time -and $null -ne $o.power_on_time.hours) { $r.PowerOnHours = $o.power_on_time.hours }
    if ($o.temperature  -and $null -ne $o.temperature.current) { $r.Temp = $o.temperature.current }
    if ($o.smart_status -and $null -ne $o.smart_status.passed) {
        $r.Verdict = if ($o.smart_status.passed) { 'OK - SMART passou' } else { '!! FALHA - SMART reprovou; faca backup JA' }
    }

    $nvme = $o.nvme_smart_health_information_log
    if ($nvme) {
        $r.Note = 'NVMe'
        if ($null -ne $nvme.power_on_hours)  { $r.PowerOnHours = $nvme.power_on_hours }
        if ($null -ne $nvme.temperature)     { $r.Temp = $nvme.temperature }
        if ($null -ne $nvme.media_errors)    { $r.Uncorr = $nvme.media_errors }
        if ($null -ne $nvme.percentage_used) { $r.Wear = $nvme.percentage_used; $r.LifeLeft = 100 - $nvme.percentage_used }
        if ($nvme.critical_warning -and $nvme.critical_warning -ne 0) {
            $r.Verdict = "!! AVISO CRITICO NVMe (critical_warning=$($nvme.critical_warning))"
        }
    } else {
        $tab = $o.ata_smart_attributes.table
        if ($tab) {
            $g = { param($id) $a = $tab | Where-Object { $_.id -eq $id } | Select-Object -First 1; if ($a) { $a.raw.value } else { $null } }
            $r.Realloc  = & $g 5
            $r.Pending  = & $g 197
            $r.Uncorr   = & $g 198
            $r.ReallEvt = & $g 196
            # desgaste SSD: 231 (SSD Life Left) / 177 (Wear Leveling) / 233 - value normalizado = % restante
            $life = $tab | Where-Object { $_.id -in @(231,177,233) } | Select-Object -First 1
            if ($life -and $null -ne $life.value) { $r.LifeLeft = $life.value; $r.Wear = 100 - $life.value }
        }
    }
    return $r
}

function Get-SmartViaWmi($diskNum, $disk) {
    $reliab = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction SilentlyContinue
    $raw    = Get-RawSmart $diskNum

    $pick = { param([bool]$dz, $vals) foreach ($v in $vals) { if ($null -eq $v) { continue }; if ("$v".Trim() -eq '') { continue }; if ($dz -and ($v -eq 0)) { continue }; return $v }; return $null }
    $attr = { param($id) if ($raw -and $raw.Attrs.ContainsKey($id)) { $raw.Attrs[$id].Raw } else { $null } }

    $verdict = $null
    if ($raw -and $null -ne $raw.PredictFailure) {
        $verdict = if ($raw.PredictFailure) { "!! FALHA PREVISTA - faca backup ja (Reason $($raw.Reason))" } else { 'OK - sem falha prevista' }
    }
    $tempAttr = $null
    if ($raw -and $raw.Attrs.ContainsKey(194)) { $tempAttr = ($raw.Attrs[194].Raw -band 0xFF) }
    $lifeLeft = $null
    if ($raw -and $raw.Attrs.ContainsKey(231)) { $lifeLeft = $raw.Attrs[231].Value }
    $wearFromLife = $null
    if ($null -ne $lifeLeft) { $wearFromLife = 100 - $lifeLeft }
    $note = $null
    if (-not $reliab -and -not $raw) { $note = 'nenhuma fonte WMI respondeu (USB/RAID?)' }

    return @{
        Source='wmi'; Model=$disk.FriendlyName; Serial=$disk.SerialNumber; Verdict=$verdict;
        PowerOnHours = (& $pick $false @($reliab.PowerOnHours, (& $attr 9)));
        Temp     = (& $pick $true  @($reliab.Temperature, $tempAttr));
        TempMax  = (& $pick $true  @($reliab.TemperatureMax));
        Realloc  = (& $pick $false @((& $attr 5), $reliab.ReadErrorsUncorrected));
        Pending  = (& $attr 197);
        Uncorr   = (& $pick $false @((& $attr 198), $reliab.ReadErrorsUncorrected));
        ReallEvt = (& $attr 196);
        ReadErr  = $reliab.ReadErrorsTotal;
        WriteErr = $reliab.WriteErrorsTotal;
        Wear     = (& $pick $false @($reliab.Wear, $wearFromLife));
        LifeLeft = $lifeLeft;
        Note     = $note
    }
}

function Exec-Smart {
    $diskNum = $script:ctx.disk.SelectedItem.Number
    $disk    = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $diskNum }
    Set-Status "Lendo SMART..." ([System.Drawing.Color]::DarkOrange)

    $script:lastSmartctlMsg = $null
    $d = Get-SmartViaCtl $diskNum
    if (-not $d) { $d = Get-SmartViaWmi $diskNum $disk }

    $verdict = $d.Verdict
    if (-not $verdict) {
        $verdict = switch ("$($disk.HealthStatus)") {
            'Healthy'   { 'OK - saudavel' }
            'Warning'   { '! ATENCAO - disco reportou avisos' }
            'Unhealthy' { '!! CRITICO - disco em pre-falha' }
            default     { Fmt-Val $disk.HealthStatus }
        }
    }

    # Temperatura com interpretacao (ok/morno/quente) e max se houver
    $tempStr = Fmt-Val $d.Temp ' C'
    $ttag = Get-TempTag $d.Temp
    if ($null -ne $d.Temp -and $ttag) { $tempStr += " ($ttag)" }
    if ($null -ne $d.TempMax) { $tempStr += "  (max: $($d.TempMax) C)" }

    # Horas com idade em anos
    $horasStr = if ($null -ne $d.PowerOnHours) { Get-HoursAge $d.PowerOnHours } else { Fmt-Val $d.PowerOnHours ' h' }

    # Vida util com faixa qualitativa
    $lifeStr = Fmt-Field $d.LifeLeft ' %' $false
    $lifeBand = Get-LifeBand $d.LifeLeft
    if (($null -ne $d.LifeLeft) -and $lifeBand) { $lifeStr += " ($lifeBand)" }

    # Aplicabilidade por tipo: setores realocados/pendentes/eventos sao conceito
    # ATA (nao se aplicam a NVMe); desgaste/vida util nao se aplicam a HDD.
    $isNVMe = ($disk.BusType -eq 'NVMe') -or ($d.Note -eq 'NVMe')
    $isHDD  = ($disk.MediaType -eq 'HDD')

    $rows = @(
        ,@('Modelo',              (Fmt-Val $d.Model))
        ,@('Serial',              (Fmt-Val $d.Serial))
        ,@('Tipo / Barramento',   "$($disk.MediaType) / $($disk.BusType)")
        ,@('Saude (resumo)',      $verdict)
        ,@('OperationalStatus',   $disk.OperationalStatus)
        ,@('Horas ligado',        $horasStr)
        ,@('Temperatura',         $tempStr)
        ,@('Setores realocados',  (Fmt-Field $d.Realloc '' $isNVMe))
        ,@('Setores pendentes',   (Fmt-Field $d.Pending '' $isNVMe))
        ,@('Setores incorrigiveis', (Fmt-Val $d.Uncorr))
        ,@('Eventos de realloc',  (Fmt-Field $d.ReallEvt '' $isNVMe))
        ,@('Erros de leitura',    (Fmt-Val $d.ReadErr))
        ,@('Erros de escrita',    (Fmt-Val $d.WriteErr))
        ,@('Desgaste (wear)',     (Fmt-Field $d.Wear ' %' $isHDD))
    )
    if (-not $isHDD) { $rows += ,@('Vida util restante', $lifeStr) }

    # --- Interpretacao curta (topo) ---
    $alertas = @()
    foreach ($pair in @(@('setores realocados', $d.Realloc), @('setores pendentes', $d.Pending), @('setores incorrigiveis', $d.Uncorr))) {
        $v = $pair[1]
        if (($null -ne $v) -and ([int64]"$v" -gt 0)) { $alertas += "$($pair[0]): $v" }
    }
    $lifeLow  = ($null -ne $d.LifeLeft) -and ($d.LifeLeft -lt 20)
    $lifeWarn = ($null -ne $d.LifeLeft) -and ($d.LifeLeft -lt 40)
    $tempHot  = ($null -ne $d.Temp) -and ($d.Temp -gt 65)
    # verdicts de falha comecam com "!!", avisos com "! " (cuidado: "sem falha prevista" e saudavel)
    $fail     = "$verdict".StartsWith('!!')
    $verdWarn = "$verdict".StartsWith('! ')

    if (($alertas.Count -gt 0) -or $lifeLow -or $fail) {
        $overall = 'RISCO ALTO - faca backup e considere trocar o disco'
    } elseif ($lifeWarn -or $tempHot -or $verdWarn) {
        $overall = 'ATENCAO - monitorar (sem urgencia)'
    } else {
        $overall = 'SAUDAVEL - nada a fazer'
    }

    $out  = "=== S.M.A.R.T. - Disk $diskNum ($($disk.FriendlyName)) ===`n`n"
    $out += ">> Interpretacao (resumo):`n"
    $out += "   Saude    : $verdict`n"
    if (-not $isHDD) { $out += "   Desgaste : $lifeStr`n" }
    $out += "   Temp     : $tempStr`n"
    if ($alertas.Count -gt 0) { $out += "   Alertas  : " + ($alertas -join '; ') + "`n" }
    $out += "   VEREDITO : $overall`n"

    # --- Detalhes (pra baixo, pra copiar) ---
    $pad = ($rows | ForEach-Object { $_[0].Length } | Measure-Object -Maximum).Maximum
    $out += "`n--- detalhes (copie pra uma IA se quiser interpretar) ---`n"
    foreach ($r in $rows) { $out += ("{0} : {1}`n" -f $r[0].PadRight($pad), $r[1]) }

    $out += "Fonte: $($d.Source)"
    if ($d.Note) { $out += " ($($d.Note))" }
    if ($d.Source -eq 'wmi') {
        $out += "`n(WMI nativo - dados limitados.)"
        if ($script:lastSmartctlMsg) { $out += "`nsmartctl rodou mas nao leu o disco: $($script:lastSmartctlMsg)" }
    }
    $out += "`nN/A = nao se aplica | N/D = nao reportado"

    Set-Output $out
    Set-Status "OK" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Info {
    $diskNum = $script:ctx.disk.SelectedItem.Number
    $d = Get-Disk -Number $diskNum
    $phy = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $diskNum }
    $out = "=== Disk $diskNum - Informacoes detalhadas ===`n`n"
    $out += "Modelo:        $($d.FriendlyName)`n"
    $out += "Serial:        $($d.SerialNumber)`n"
    $out += "Firmware:      $($d.FirmwareVersion)`n"
    $out += "Tipo:          $($phy.MediaType) ($($phy.BusType))`n"
    $out += "Tamanho:       $(Format-Bytes $d.Size)`n"
    $out += "Tabela:        $($d.PartitionStyle)`n"
    $out += "Boot/Sistema:  Boot=$($d.IsBoot) / System=$($d.IsSystem)`n`n"
    $out += "Particoes:`n"
    Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue | ForEach-Object {
        $letter = if ($_.DriveLetter) { "$($_.DriveLetter):" } else { "(sem letra)" }
        $type = $_.Type
        $fs = ""
        try { $fs = (Get-Volume -Partition $_).FileSystem } catch {}
        $label = ""
        try { $label = (Get-Volume -Partition $_).FileSystemLabel } catch {}
        $out += "  Part $($_.PartitionNumber): $letter  $(Format-Bytes $_.Size)  $type  $fs  '$label'`n"
    }
    Set-Output $out
    Set-Status "OK" ([System.Drawing.Color]::DarkGreen)
}

function Populate-Overview {
    $lv = $script:ctx.overviewList
    if (-not $lv) { return }
    $lv.Items.Clear()
    Set-Status "Lendo discos..." ([System.Drawing.Color]::DarkOrange)
    $lettersMap = Get-DiskLettersMap
    $disks = Get-AllDisks
    $dupModels = @($disks | Group-Object FriendlyName | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

    foreach ($d in $disks) {
        $n = [int]$d.Number
        $phys = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $n }
        $mt = if ($phys) { "$($phys.MediaType)" } else { '' }
        $bus = if ($phys) { "$($phys.BusType)" } else { "$($d.BusType)" }
        $type = if ($bus -eq 'NVMe') { 'NVMe' } elseif ($mt) { $mt } else { '?' }
        $health = if ($phys) { "$($phys.HealthStatus)" } else { "$($d.HealthStatus)" }

        $name = $d.FriendlyName
        if (($dupModels -contains $name) -and $d.SerialNumber) {
            $sn = "$($d.SerialNumber)".Trim()
            $tail = if ($sn.Length -gt 5) { $sn.Substring($sn.Length - 5) } else { $sn }
            $name = "$name (SN..$tail)"
        }

        $sm = Get-SmartViaCtl $n
        if (-not $sm -and $phys) { $sm = Get-SmartViaWmi $n $phys }
        if ($mt -eq 'HDD') {
            $life = 'N/A (HDD)'
        } elseif ($null -ne $sm.LifeLeft) {
            $b = Get-LifeBand $sm.LifeLeft
            $life = "$($sm.LifeLeft)% ($b)"
        } else {
            $life = 'N/D'
        }
        $letters = if ($lettersMap.ContainsKey($n)) { $lettersMap[$n] } else { '-' }

        $item = New-Object System.Windows.Forms.ListViewItem("$n")
        $item.SubItems.Add($name) | Out-Null
        $item.SubItems.Add($type) | Out-Null
        $item.SubItems.Add($health) | Out-Null
        $item.SubItems.Add($life) | Out-Null
        $item.SubItems.Add($letters) | Out-Null
        $lv.Items.Add($item) | Out-Null
    }
    Set-Status "Visao geral atualizada ($(@($disks).Count) discos)" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Activate {
    $out = "=== Ativacao do Windows ===`n`n"
    $svc = Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue
    $oemKey = if ($svc) { $svc.OA3xOriginalProductKey } else { $null }

    if ($script:ctx.reactivate.Checked) {
        if ($oemKey) {
            Set-Status "Instalando chave OEM e ativando..." ([System.Drawing.Color]::DarkOrange)
            $slmgr = "$env:windir\system32\slmgr.vbs"
            cscript //nologo $slmgr /ipk $oemKey 2>&1 | Out-Null
            cscript //nologo $slmgr /ato   2>&1 | Out-Null
            $out += "Reativacao executada com a chave OEM do firmware.`n`n"
        } else {
            $out += "Reativacao pedida, mas NAO ha chave OEM no firmware - nada a reativar.`n`n"
        }
    }

    $prod = Get-CimInstance SoftwareLicensingProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Windows*' -and $_.PartialProductKey } | Select-Object -First 1

    $rows = @()
    if ($oemKey) {
        $k = "$oemKey"; $ktail = if ($k.Length -gt 5) { $k.Substring($k.Length - 5) } else { $k }
        $rows += ,@('Chave OEM (firmware)', "presente (...$ktail)")
    } else {
        $rows += ,@('Chave OEM (firmware)', 'nenhuma (placa sem licenca embutida, ou Volume/Retail)')
    }

    if ($prod) {
        $ch = "$($prod.ProductKeyChannel)"
        $chTxt = switch -Wildcard ($ch) {
            'OEM*'         { 'OEM (placa-mae/fabricante)' }
            'Retail*'      { 'Retail' }
            'Volume:MAK*'  { 'Volume (MAK)' }
            'Volume:GVLK*' { 'Volume (KMS)' }
            default        { if ($ch) { $ch } else { 'desconhecido' } }
        }
        $st = [int]$prod.LicenseStatus
        $stTxt = switch ($st) {
            1 { 'ATIVADO' }
            0 { 'NAO ativado' }
            2 { 'Carencia (OOB)' }
            3 { 'Carencia (OOT)' }
            4 { 'Carencia (nao genuino)' }
            5 { 'Notificacao (nao ativado)' }
            6 { 'Carencia estendida' }
            default { "status $st" }
        }
        $perm = ($ch -like 'OEM*' -or $ch -like 'Retail*')
        if ($st -eq 1 -and $perm) {
            $val = 'Permanente (sem expiracao)'
        } elseif ($prod.GracePeriodRemaining -and $prod.GracePeriodRemaining -gt 0) {
            $dias = [math]::Round($prod.GracePeriodRemaining / 1440.0, 0)
            $val = "expira/renova em ~$dias dias (Volume/KMS ou carencia)"
        } elseif ($st -eq 1) {
            $val = 'Ativado (sem data de expiracao reportada)'
        } else {
            $val = 'sem ativacao permanente'
        }
        $rows += ,@('Produto', "$($prod.Name)")
        $rows += ,@('Chave instalada (ult.5)', "$($prod.PartialProductKey)")
        $rows += ,@('Tipo de licenca', $chTxt)
        $rows += ,@('Status', $stTxt)
        $rows += ,@('Validade', $val)
    } else {
        $rows += ,@('Status', 'nao foi possivel ler o produto Windows')
    }

    $pad = ($rows | ForEach-Object { $_[0].Length } | Measure-Object -Maximum).Maximum
    foreach ($r in $rows) { $out += ("{0} : {1}`n" -f $r[0].PadRight($pad), $r[1]) }
    if ((-not $script:ctx.reactivate.Checked) -and $oemKey -and ((-not $prod) -or ([int]$prod.LicenseStatus -ne 1))) {
        $out += "`nDica: marque 'Forcar reativacao' pra instalar a chave OEM e ativar."
    }

    Set-Output $out
    Set-Status "Ativacao: verificado" ([System.Drawing.Color]::DarkGreen)
}

# --- INTERNET/WIFI ---
function Exec-Termico {
    Set-Status "Medindo calor e energia..." ([System.Drawing.Color]::DarkOrange)

    $linhas = @(Get-TermicoLinhas -ComDisco)

    $extra = ''
    if ($script:ctx.batreport -and $script:ctx.batreport.Checked) {
        # -ErrorAction nao pega excecao .NET (WMI quebrado); por isso o try/catch tambem.
        $temBat = $false
        try { $temBat = $null -ne (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) } catch { $temBat = $false }
        if (-not $temBat) {
            # Desktop: powercfg /batteryreport falha com 0x10d2 e o erro cru vazava pro log.
            $extra = "`nRelatorio de bateria: nao gerado - esta maquina nao tem bateria (desktop)."
        } else {
            $rel = Join-Path (Get-PastaBackup) 'bateria.html'
            cmd /c "powercfg /batteryreport /output ""$rel"" >nul 2>&1"
            $extra = if (Test-Path $rel) { "`nRelatorio de bateria salvo em: $rel" } else { "`nNao consegui gerar o relatorio de bateria." }
        }
    }

    $out  = "=== Calor e bateria - $(Get-Date -f 'dd/MM/yyyy HH:mm') ===`n"
    $out += "$((Get-CimInstance Win32_ComputerSystem).Manufacturer) $((Get-CimInstance Win32_ComputerSystem).Model)`n"
    $out += "$((Get-CimInstance Win32_Processor).Name)`n`n"
    $out += ($linhas -join "`n")
    $out += "`n$extra"

    if ($script:ctx.termLog -and $script:ctx.termLog.Checked) {
        try {
            $dst = Join-Path (Get-PastaBackup) ("termico_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -f 'yyyy-MM-dd_HHmm'))
            $out | Out-File $dst -Encoding utf8
            $out += "`nLog salvo em: $dst"
        } catch { $out += "`nNao consegui salvar o log: $($_.Exception.Message)" }
    }
    $out += "`n`n--- pode colar este texto numa IA pra interpretar ---"

    Set-Output $out
    Set-Status "Medicao concluida" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Checkup {
    Set-Status "Coletando indicadores..." ([System.Drawing.Color]::DarkOrange)
    $pasta = Get-PastaBackup
    $base  = Join-Path $pasta 'checkup-linha-de-base.json'
    $L = New-Object System.Collections.Generic.List[string]
    function AC($t) { $L.Add($t) }
    $m = @{}

    function ContaEv($prov, $ids, $dias) {
        # Id=$null no FilterHashtable NAO e "qualquer id": quebra a consulta.
        # E provider que nunca escreveu evento LANCA - e isso e zero, nao erro.
        $f = @{ LogName='System'; ProviderName=$prov; StartTime=(Get-Date).AddDays(-$dias) }
        if ($null -ne $ids) { $f['Id'] = $ids }
        try { @(Get-WinEvent -FilterHashtable $f -ErrorAction Stop).Count } catch { 0 }
    }

    AC ("=== CHECKUP - {0} ===" -f (Get-Date -f 'dd/MM/yyyy HH:mm'))
    try {
        $bi = Get-CimInstance Win32_BIOS; $bb = Get-CimInstance Win32_BaseBoard
        $m.bios = "$($bi.SMBIOSBIOSVersion) de $($bi.ReleaseDate.ToString('dd/MM/yyyy'))"
        AC ("BIOS {0} | {1} rev {2}" -f $m.bios, $bb.Product, $bb.Version)
    } catch { AC 'BIOS: nao consegui ler' }

    AC ''
    AC '--- MEMORIA (flashar a BIOS zera o XMP) ---'
    try {
        $ram = @(Get-CimInstance Win32_PhysicalMemory)
        $cfg = ($ram | Measure-Object -Property ConfiguredClockSpeed -Maximum).Maximum
        $max = ($ram | Measure-Object -Property Speed -Maximum).Maximum
        $tot = [math]::Round((($ram | Measure-Object -Property Capacity -Sum).Sum)/1GB,1)
        $m.ram_cfg = $cfg
        # Speed devolve o teto JEDEC, nao o do XMP: com XMP ligado o configurado fica ACIMA dele.
        AC ("{0} pente(s), {1} GB | rodando a {2} MHz | JEDEC base {3} MHz" -f $ram.Count,$tot,$cfg,$max)
        foreach ($r in $ram) { AC ("   {0} {1} | {2} MHz" -f $r.Manufacturer, $r.PartNumber, $r.ConfiguredClockSpeed) }
        if ($cfg -and $max -and $cfg -lt $max) { AC '>>> XMP DESLIGADO: a RAM esta abaixo do que o pente suporta.' }
        elseif ($cfg -le 2133) {
            AC '>>> ATENCAO: 2133 MHz e o JEDEC base do DDR4 - e onde a RAM fica com XMP DESLIGADO.'
            AC '    Conferir o part number acima: se for 3200/3600, ligar o XMP no BIOS (Tweaker > X.M.P. > Profile1).'
        } else { AC ("ok: {0} MHz, acima do JEDEC base - XMP LIGADO." -f $cfg) }
    } catch { AC 'memoria: nao consegui ler' }

    AC ''
    AC '--- CONTADORES ---'
    $m.id55_30   = ContaEv 'Microsoft-Windows-Kernel-Processor-Power' 55 30
    $m.id55_90   = ContaEv 'Microsoft-Windows-Kernel-Processor-Power' 55 90
    $m.whea_90   = ContaEv 'Microsoft-Windows-WHEA-Logger' $null 90
    $m.fastfail  = ContaEv 'Microsoft-Windows-Kernel-Boot' 29 90
    $m.termico   = ContaEv 'Microsoft-Windows-Kernel-Thermal' $null 90
    try { $m.quedas_90 = @(Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6008; StartTime=(Get-Date).AddDays(-90)} -EA SilentlyContinue |
                           Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') }).Count } catch { $m.quedas_90 = 0 }
    $m.minidumps = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -Force -EA SilentlyContinue).Count
    AC ("Kernel-Processor-Power ID 55 .. {0} em 30d | {1} em 90d" -f $m.id55_30, $m.id55_90)
    $nT = [int]$env:NUMBER_OF_PROCESSORS; if ($nT -lt 1) { $nT = 1 }
    try {
        $g = @(Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Processor-Power'; Id=55;
               StartTime=(Get-Date).AddDays(-90)} -EA SilentlyContinue | Group-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') })
        $m.id55_rajadas = $g.Count
        $porRaj = if ($g.Count) { [int](($g | Measure-Object -Property Count -Average).Average) } else { 0 }
        if ($g.Count) {
            AC ("   -> {0} RAJADA(S) de ~{1} eventos (a maquina tem {2} threads)" -f $g.Count, $porRaj, $nT)
            if ($porRaj -ge ($nT - 2)) { AC '   -> ~1 por nucleo: padrao de boot. Contar RAJADAS, nao eventos.' }
        }
    } catch { $m.id55_rajadas = -1 }
    AC ("WHEA (erro de hardware) ....... {0} em 90d" -f $m.whea_90)
    AC ("quedas (41/6008, por minuto) .. {0} em 90d" -f $m.quedas_90)
    AC ("falhas de Fast Startup ........ {0} em 90d" -f $m.fastfail)
    AC ("eventos de zona termica ....... {0} em 90d  (0 = o Windows nunca viu calor perigoso)" -f $m.termico)
    AC ("minidumps ..................... {0}" -f $m.minidumps)

    AC ''
    AC '--- ULTIMA OCORRENCIA (e esta que fecha o caso) ---'
    foreach ($par in @(@('Microsoft-Windows-Kernel-Processor-Power',55,'ID 55'),
                       @('Microsoft-Windows-WHEA-Logger',$null,'WHEA'))) {
        $f = @{ LogName='System'; ProviderName=$par[0]; StartTime=(Get-Date).AddDays(-120) }
        if ($null -ne $par[1]) { $f['Id'] = $par[1] }
        try {
            $e = @(Get-WinEvent -FilterHashtable $f -EA Stop | Select-Object -First 1)
            AC ("{0,-6}: {1:dd/MM/yyyy HH:mm:ss}  (ha {2} dias)" -f $par[2], $e[0].TimeCreated, [int]((Get-Date)-$e[0].TimeCreated).TotalDays)
        } catch { AC ("{0,-6}: nenhum em 120 dias" -f $par[2]) }
    }
    try { $os = Get-CimInstance Win32_OperatingSystem
          AC ("ligado desde {0:dd/MM/yyyy HH:mm} ({1:N1} dias)" -f $os.LastBootUpTime, ((Get-Date)-$os.LastBootUpTime).TotalDays) } catch {}

    AC ''
    AC '--- CLOCK (nominal = 100%) ---'
    Set-Status "Medindo o clock sob carga (~13 s)..." ([System.Drawing.Color]::DarkOrange)
    [System.Windows.Forms.Application]::DoEvents()
    $i = Get-ClockAgora                       # ja usa PercentProcessorPerformance (passa de 100%)
    $m.clock_idle = if ($i) { [int]$i.Perf } else { -1 }
    AC ("ocioso .... {0}%" -f $m.clock_idle)
    $c = Test-CargaClock -Segundos 10
    if ($c) {
        $m.clock_carga = [int]$c.Perf
        # Start-Job nao satura CPU de muitos threads. Clock ALTO com carga parcial ja
        # PROVA que o turbo sobe; o que carga parcial nao pode fazer e CONDENAR o turbo.
        if ($c.Perf -ge 150) {
            AC ("sob carga . {0}%  -> TURBO OK (uso {1}%)" -f [int]$c.Perf, [int]$c.Uso)
        } elseif ($c.Uso -lt 50) {
            AC ("sob carga . {0}%  -> INCONCLUSIVO: a carga so chegou a {1}% de uso." -f [int]$c.Perf, [int]$c.Uso)
            AC "            Nao da p/ condenar o turbo assim. Use a acao 'Energia / clock da CPU'."
        } else {
            AC ("sob carga . {0}%  com uso de {1}%: isso e sintoma. Investigar." -f [int]$c.Perf, [int]$c.Uso)
        }
    } else { $m.clock_carga = -1; AC 'sob carga . nao consegui medir' }

    AC ''
    AC '=============================================='
    if (Test-Path $base) {
        try {
            $ant = Get-Content $base -Raw | ConvertFrom-Json
            AC ("COMPARACAO com {0}" -f $ant.quando)
            AC ("BIOS: {0}  ->  {1}" -f $ant.m.bios, $m.bios)
            AC ''
            AC ("{0,-26} {1,10} {2,10}   {3}" -f 'metrica','antes','agora','')
            foreach ($k in @('id55_30','id55_90','id55_rajadas','whea_90','quedas_90','fastfail','termico','minidumps','clock_carga','ram_cfg')) {
                $a = [double]$ant.m.$k; $b = [double]$m.$k
                $nota = if ($k -in @('clock_carga','ram_cfg')) { if ($b -ge $a) { 'ok' } else { 'CAIU - investigar' } }
                        elseif ($b -lt $a) { 'MELHOROU' } elseif ($b -gt $a) { 'subiu' } else { 'igual' }
                AC ("{0,-26} {1,10} {2,10}   {3}" -f $k, $a, $b, $nota)
            }
            AC ''
            AC 'Leitura: os contadores sao janela movel de 30/90 dias - so caem quando o'
            AC 'evento VELHO sai da janela. O que fecha o caso e a ULTIMA OCORRENCIA acima:'
            AC 'se ficou parada no dia em que voce mexeu, resolveu.'
        } catch { AC ("nao consegui ler a linha de base: {0}" -f $_.Exception.Message) }
    } else {
        AC 'PRIMEIRA RODADA - linha de base gravada.'
        AC 'Rode de novo depois de mexer na maquina e ele mostra o antes/depois sozinho.'
    }
    AC '=============================================='

    $out = ($L -join "`n")
    try { @{ quando=(Get-Date -f 'dd/MM/yyyy HH:mm'); m=$m } | ConvertTo-Json -Depth 4 | Out-File $base -Encoding utf8 }
    catch { $out += "`nNao consegui gravar a linha de base: $($_.Exception.Message)" }
    if ($script:ctx.ckLog -and $script:ctx.ckLog.Checked) {
        try {
            $dst = Join-Path $pasta ("checkup_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -f 'yyyy-MM-dd_HHmm'))
            $out | Out-File $dst -Encoding utf8
            $out += "`nLog salvo em: $dst"
        } catch { $out += "`nNao consegui salvar o log: $($_.Exception.Message)" }
    }
    $out += "`n`n--- pode colar este texto numa IA pra interpretar ---"
    Set-Output $out
    Set-Status "Checkup concluido" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Energia {
    $aplicar = ($script:ctx.enFix -and $script:ctx.enFix.Checked)
    if ($aplicar) {
        if (-not (Confirm-Action ("Liberar a energia desta maquina?`n`n" +
            "- teto do processador em 100% e piso em 5% (AC e bateria)`n" +
            "- turbo em modo agressivo`n" +
            "- economia de energia so manual (nunca liga sozinha)`n" +
            "- slider em Melhor desempenho + Power Throttling desligado`n`n" +
            "Vale na hora, sem reiniciar, e e' tudo reversivel.`n" +
            "Em notebook pode esquentar e gastar mais bateria."))) { $aplicar = $false }
    }

    $out = "=== Energia / clock da CPU - $(Get-Date -f 'dd/MM/yyyy HH:mm') ===`n"
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $cp = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $bi = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $out += "$($cs.Manufacturer) $($cs.Model) | $($cp.Name) | nominal $($cp.MaxClockSpeed) MHz`n"
        $out += ("BIOS: {0} de {1:dd/MM/yyyy}  <- conferir no site pelo machine type, nao pelo Vantage/SupportAssist`n" -f $bi.SMBIOSBIOSVersion, $bi.ReleaseDate)
    } catch {}

    Set-Status "Medindo o clock em repouso..." ([System.Drawing.Color]::DarkOrange)
    $idle = Get-ClockAgora
    if ($idle) { $out += ("`nANTES, ocioso: {0}% do nominal (~{1} GHz) | uso de CPU {2}%`n" -f [math]::Round($idle.Perf), (Get-ClockGhz $idle.Perf), [math]::Round($idle.Uso)) }
    else       { $out += "`nANTES, ocioso: contador de clock indisponivel nesta maquina`n" }

    $antes = Test-CargaClock -Segundos 10 -Rotulo 'ANTES'
    $out += ("ANTES, sob carga: PICO {0}% do nominal (~{1} GHz) | uso de CPU chegou a {2}%`n" -f [math]::Round($antes.Perf), (Get-ClockGhz $antes.Perf), [math]::Round($antes.Uso))

    Set-Status "Lendo a configuracao de energia..." ([System.Drawing.Color]::DarkOrange)
    $out += "`n--- COMO A ENERGIA ESTA ---`n"
    $out += ((Get-EnergiaConfigLinhas) -join "`n") + "`n"

    $depois = $antes
    if ($aplicar) {
        Set-Status "Liberando a energia..." ([System.Drawing.Color]::DarkOrange)
        $out += "`n--- CORRECOES APLICADAS ---`n"
        $out += ((Set-EnergiaLiberada | ForEach-Object { "[OK] $_" }) -join "`n") + "`n"
        Start-Sleep -Seconds 2
        $depois = Test-CargaClock -Segundos 10 -Rotulo 'DEPOIS'
        $out += ("`nDEPOIS, sob carga: PICO {0}% do nominal (~{1} GHz)`n" -f [math]::Round($depois.Perf), (Get-ClockGhz $depois.Perf))
        $t = Get-EnergiaValor $script:EN.SubProc $script:EN.ThrotMax
        $out += ("Teto do processador agora: AC {0}% | bateria {1}%`n" -f $t[0], $t[1])
    } else {
        $out += "`n(so medicao: a caixa 'Liberar a energia' estava desmarcada ou voce cancelou - nada foi alterado)`n"
    }

    # --- veredito ---
    $out += "`n--- VEREDITO ---`n"
    if ($depois.Uso -lt 50) {
        $out += ("TESTE DE CARGA NAO VALEU: o uso de CPU so chegou a {0}% - a carga nao pegou`n" -f [math]::Round($depois.Uso))
        $out += "(Start-Job bloqueado por politica, ou contador de CPU quebrado). Sem veredito de clock:`n"
        $out += "repita com o PC na tomada, ou olhe a frequencia no Monitor de Recursos rodando algo pesado.`n"
        if ($aplicar) { $out += "As correcoes de energia acima valem de qualquer forma.`n" }
    } elseif ($depois.Perf -ge 80) {
        $out += ("CPU SOBE NORMAL ({0}% do nominal sob carga). Nao esta presa.`n" -f [math]::Round($depois.Perf))
        if ($aplicar -and $antes.Perf -lt 60) { $out += "E era CONFIGURACAO DE ENERGIA: subiu depois das correcoes. Caso resolvido.`n" }
        else { $out += "Se o PC ainda esta lento, a causa NAO e' clock: olhar disco (S.M.A.R.T.), RAM, antivirus e startup.`n" }
    } elseif ($depois.Perf -ge 50) {
        $out += ("SOBE PARCIAL ({0}%). Cheira a limite termico/firmware:`n" -f [math]::Round($depois.Perf))
        $out += "1) BIOS nova pelo site do fabricante usando o machine type acima`n"
        $out += "2) rodar aqui a acao 'Calor e bateria' pra cruzar temperatura com carga`n"
    } else {
        $out += ("CPU PRESA: nao passa de {0}% do nominal nem sob carga.`n" -f [math]::Round($depois.Perf))
        if ($aplicar) { $out += "Com a energia do Windows toda liberada -> energia DESCARTADA. Arvore de descarte:`n" }
        else { $out += "Marque 'Liberar a energia' e rode de novo antes de culpar o hardware. Depois:`n" }
        $fab = ''; $ser = ''; $mod = ''; $sku = ''
        try { $c2 = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop; $fab = "$($c2.Manufacturer)"; $mod = "$($c2.Model)"; $sku = "$($c2.SystemSKUNumber)" } catch {}
        try { $ser = "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber)" } catch {}
        $n = 1
        if ($script:enSemBateria) {
            $out += "$n) BD PROCHOT - com bateria NAO detectada, e o suspeito nº1: o circuito da bateria levanta esse`n"
            $out += "   sinal e, preso em alto, a CPU fica no multiplicador minimo, FRIA, e reboot nao resolve.`n"
            $out += "   Ver/desmarcar no ThrottleStop portable (caixa BD PROCHOT) - o clock sobe na hora se for isso.`n"
            $out += "   Paliativo: desliga uma protecao, entao vigiar temperatura. PowerShell nao alcanca (e MSR).`n"
            $n++
        }
        $comoBios = if ($fab -match 'Dell') { "Dell: pela SERVICE TAG ($ser), nao pelo SupportAssist" }
                    elseif ($fab -match 'Lenovo') { "Lenovo: pelo MACHINE TYPE ($sku), NAO pelo Vantage (ja escondeu 6 revisoes)" }
                    elseif ($fab -match 'HP|Hewlett') { "HP: pelo numero de produto/serial ($ser)" }
                    elseif ($fab -match 'ASUS') { "ASUS: pelo modelo exato ($mod), nao pelo MyASUS" }
                    else { "pelo modelo/serial ($mod / $ser)" }
        $out += "$n) BIOS nova (evento 37 = firmware limitando) - $comoBios`n"; $n++
        $out += "$n) CARREGADOR original e com watt suficiente: nao reconhecido (BIOS: 'AC Adapter Unknown') ou fraco`n"
        $out += "   faz o firmware limitar a CPU de proposito - e sem bateria pra amortecer, piora.`n"; $n++
        $out += "$n) bateria: capacidade de projeto x carga total (acao 'Calor e bateria')`n"; $n++
        if ($fab -match 'Lenovo') {
            $out += "$n) modo termico: IdeaPad = Fn+Q alterna 3 modos`n"; $n++
            $out += "$n) reset de EC: no IdeaPad e o FURINHO (Novo/reset) na base, 10 s com clipe - NAO e segurar o power`n"; $n++
        } elseif ($fab -match 'Dell') {
            $out += "$n) BIOS (F2): conferir 'AC Adapter Type' e a saude/presenca da bateria na propria tela`n"; $n++
            $out += "$n) reset de EC: desligar, tirar o carregador, segurar o power 30 s, religar so na tomada`n"; $n++
        } else {
            $out += "$n) modo termico/desempenho do fabricante (tecla de funcao ou app proprio)`n"; $n++
            $out += "$n) reset de EC: desligar, tirar carregador (e bateria, se removivel), segurar o power 30 s`n"; $n++
        }
        $out += "   depois: BIOS -> Load Defaults`n"
        $out += "$n) prova final: bootar Linux live e rodar 'grep cpu.MHz /proc/cpuinfo'. Preso la tambem = placa/firmware, Windows inocente -> garantia`n"
    }

    if ($script:ctx.enLog -and $script:ctx.enLog.Checked) {
        try {
            $dst = Join-Path (Get-PastaBackup) ("energia_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -f 'yyyy-MM-dd_HHmm'))
            $out | Out-File $dst -Encoding utf8
            $out += "`nLog salvo em: $dst"
        } catch { $out += "`nNao consegui salvar o log: $($_.Exception.Message)" }
    }
    $out += "`n`n--- pode colar este texto numa IA pra interpretar ---"

    Set-Output $out
    Set-Status "Energia: medicao concluida" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Aer {
    Set-Status "Contando erros de hardware reportados (WHEA)..." ([System.Drawing.Color]::DarkOrange)

    $out = "=== PCIe / WHEA - $(Get-Date -f 'dd/MM/yyyy HH:mm') ===`n"
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $out += "$($cs.Manufacturer) $($cs.Model)`n"
    } catch {}
    $out += "`n" + ((Get-WheaLinhas) -join "`n") + "`n"

    $aplicar = ($script:ctx.aerFix -and $script:ctx.aerFix.Checked)
    if ($aplicar) {
        if (Confirm-Action ("Desligar o ASPM (gerenciamento de energia do link PCIe)?`n`n" +
            "E' o teste padrao pra tempestade de erro corrigido no PCI Express.`n" +
            "Vale em AC e bateria, e' reversivel, e SO passa a valer depois de REINICIAR.`n`n" +
            "Custo: um pouco mais de consumo em repouso (o link deixa de dormir).")) {
            if (Set-AspmDesligado) {
                $out += "`n[OK] ASPM desligado em AC e bateria. REINICIE o PC e rode esta acao de novo.`n"
                $out += "     Se a contagem cair pra zero, era ASPM. Se continuar, o proximo passo e FISICO:`n"
                $out += "     reassentar a placa Wi-Fi e o NVMe (nos notebooks ficam sob a mesma tampa).`n"
            } else {
                $out += "`n[FALHOU] nao consegui confirmar o ASPM em 0 - este plano de energia pode nao expor a opcao.`n"
            }
        } else { $out += "`n(cancelado: ASPM nao foi alterado)`n" }
    } else {
        $out += "`n--- VEREDITO ---`n"
        if ($script:aerTempestade -and $script:aspmLigado) {
            $out += "TEMPESTADE de erro CORRIGIDO com o ASPM ligado -> marque 'Desligar o ASPM',`n"
            $out += "execute, REINICIE e rode esta acao de novo pra comparar a contagem.`n"
        } elseif ($script:aerTempestade) {
            $out += "TEMPESTADE de erro corrigido, mas o ASPM ja esta desligado -> nao e energia do link.`n"
            $out += "Proximo passo e FISICO: reassentar a placa Wi-Fi e o NVMe. Depois, driver/BIOS.`n"
        } else {
            $out += "Sem tempestade. Se havia evento FATAL na lista acima, isso e hardware - garantia.`n"
        }
    }

    if ($script:ctx.aerLog -and $script:ctx.aerLog.Checked) {
        try {
            $dst = Join-Path (Get-PastaBackup) ("whea-pcie_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -f 'yyyy-MM-dd_HHmm'))
            $out | Out-File $dst -Encoding utf8
            $out += "`nLog salvo em: $dst"
        } catch { $out += "`nNao consegui salvar o log: $($_.Exception.Message)" }
    }
    $out += "`n`n--- pode colar este texto numa IA pra interpretar ---"

    Set-Output $out
    Set-Status "WHEA/PCIe: leitura concluida" ([System.Drawing.Color]::DarkGreen)
}

function Exec-NetDiag {
    Set-Status "Diagnosticando rede..." ([System.Drawing.Color]::DarkOrange)

    $up = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface } | Select-Object -First 1
    $isWifi = $false
    if ($up) { $isWifi = ($up.PhysicalMediaType -like '*802.11*') -or ($up.InterfaceDescription -match 'Wi-?Fi|Wireless') }

    # Detalhes WiFi via netsh (key : value), tolerante a idioma
    $wlanRaw = (netsh wlan show interfaces 2>$null | Out-String)
    $kv = @{}
    foreach ($line in ($wlanRaw -split "`n")) {
        if ($line -match '^\s*([^:]+?)\s*:\s*(.+?)\s*$') { $kv[$matches[1].Trim()] = $matches[2].Trim() }
    }
    $pick = { param($rx) foreach ($k in $kv.Keys) { if ($k -imatch $rx) { return $kv[$k] } } return $null }
    $sigStr = & $pick 'sinal|signal'
    $sig    = if ($sigStr) { [int]($sigStr -replace '\D', '') } else { $null }
    $band   = & $pick 'banda|^band'
    $radio  = & $pick 'r.dio|radio type'
    $chan   = & $pick 'canal|channel'
    # muitas placas (ex: AX210) nao imprimem "Banda" no netsh -> deduz do canal
    if (-not $band -and $chan) {
        $cn = [int]("$chan" -replace '\D', '')
        if ($cn -ge 1 -and $cn -le 14)        { $band = '2.4 GHz (deduzido do canal)' }
        elseif ($cn -ge 32 -and $cn -le 177)  { $band = '5 GHz (deduzido do canal)' }
    }

    $gw = (Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop

    $pingStat = {
        param($target, $count)
        $r = Test-Connection -ComputerName $target -Count $count -ErrorAction SilentlyContinue
        $ok = @($r).Count
        $loss = $count - $ok
        $avg = if ($ok -gt 0) { [math]::Round((@($r) | Measure-Object ResponseTime -Average).Average) } else { $null }
        return @{ LossPct = [math]::Round(100 * $loss / $count); Avg = $avg; Ok = $ok }
    }
    $gwP  = if ($gw) { & $pingStat $gw 8 } else { $null }
    $netP = & $pingStat '8.8.8.8' 8

    # Teste de velocidade de download (throughput real, opcional)
    $dl = $null
    if ($script:ctx.speedtest -and $script:ctx.speedtest.Checked) {
        Set-Status "Medindo velocidade de download (~20 MB)..." ([System.Drawing.Color]::DarkOrange)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $tmp = "$env:TEMP\ign_spdtest.bin"
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Invoke-WebRequest -Uri 'https://speed.cloudflare.com/__down?bytes=20000000' -OutFile $tmp -UseBasicParsing -ErrorAction Stop
            $sw.Stop()
            $secs = $sw.Elapsed.TotalSeconds
            $sizeMB = (Get-Item $tmp).Length / 1MB
            if ($secs -gt 0) { $dl = [math]::Round(($sizeMB * 8) / $secs, 1) }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        } catch { $dl = $null }
    }
    $dlQual = if ($null -eq $dl) { '' }
              elseif ($dl -ge 100) { '(excelente)' }
              elseif ($dl -ge 50)  { '(bom)' }
              elseif ($dl -ge 20)  { '(ok)' }
              elseif ($dl -ge 5)   { '(lento p/ varios dispositivos)' }
              else                 { '(muito lento)' }
    $dlTxt = if ($null -ne $dl) { "$dl Mbps $dlQual" } else { 'nao testado / falhou' }

    # Alertas e veredito
    $problemas = @()
    if ($isWifi -and ($null -ne $sig) -and ($sig -lt 60)) { $problemas += "sinal WiFi fraco ($sig%)" }
    if ($isWifi -and ($band -match '2[.,]?4')) { $problemas += "rede 2.4 GHz (lenta/congestionada - prefira 5 GHz)" }

    $gwBad  = $gwP -and (($gwP.LossPct -ge 10) -or (($null -ne $gwP.Avg) -and ($gwP.Avg -gt 30)))
    $netBad = ($netP.Ok -eq 0) -or ($netP.LossPct -ge 10) -or (($null -ne $netP.Avg) -and ($netP.Avg -gt 80))
    if ($gwBad) {
        $culpa = "WiFi/PC - o link ate o roteador ja esta ruim (sinal/placa/driver)."
    } elseif ($netBad) {
        $culpa = "ROTEADOR ou PROVEDOR - o roteador responde bem, mas a internet esta ruim. Nao e o seu PC."
    } elseif (($null -ne $dl) -and ($dl -lt 10)) {
        $culpa = "BANDA/PROVEDOR - latencia boa, mas download baixo ($dl Mbps). O gargalo e a internet/plano, nao o seu PC."
    } else {
        $culpa = "Conexao saudavel - latencia e perda dentro do normal."
    }

    $tipoConn = if ($isWifi) { 'WiFi' } else { 'cabeada' }
    $adapTxt  = if ($up) { "$($up.Name) ($tipoConn)" } else { 'nenhum ativo' }
    $sigQual  = if ($null -eq $sig) { '' } elseif ($sig -ge 75) { '(bom)' } elseif ($sig -ge 60) { '(ok)' } else { '(fraco)' }
    $sigTxt   = if ($null -ne $sig) { "$sig% $sigQual" } else { 'N/D' }
    $gwTxt    = if ($gwP) { "$($gwP.Avg) ms, perda $($gwP.LossPct)%" } else { 'N/D' }
    $netTxt   = if ($netP.Ok -gt 0) { "$($netP.Avg) ms, perda $($netP.LossPct)%" } else { 'sem resposta' }

    $out  = "=== Diagnostico de rede ===`n`n"
    $out += ">> Interpretacao (resumo):`n"
    $out += "   Adaptador    : $adapTxt`n"
    if ($isWifi) {
        $out += "   Sinal WiFi   : $sigTxt`n"
        $out += "   Banda/radio  : $(Fmt-Val $band) / $(Fmt-Val $radio)`n"
    }
    $out += "   Ping roteador: $gwTxt`n"
    $out += "   Ping internet: $netTxt`n"
    $out += "   Download     : $dlTxt`n"
    if ($problemas.Count -gt 0) { $out += "   Alertas      : " + ($problemas -join '; ') + "`n" }
    $out += "   VEREDITO     : $culpa`n"
    $out += "`n--- detalhes (copie pra uma IA se quiser interpretar) ---`n"
    $out += $wlanRaw

    Set-Output $out
    Set-Status "Diagnostico de rede concluido" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Uti {
    $cmd = 'irm https://raw.githubusercontent.com/GCintra00/limpeza/master/uti-v6.ps1 | iex'
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd
    Set-Output ("UTI aberta em janela propria (ela mesma se eleva pra admin se precisar).`n" +
                "Acompanhe por la. Ao final: REINICIAR o PC.`n" +
                "Log + backups da inicializacao: Desktop\UTI-backup")
    Set-Status "UTI lancada em nova janela" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Rastreador {
    $cmd = 'irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/rastreador-acessos-remotos.ps1 | iex'
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd
    Set-Output ("Rastreador aberto em janela propria (leva menos de 1 minuto).`n`n" +
                "Veredito na tela: ACHADO / REVISAR / LIMPO.`n" +
                "Relatorio: Desktop\acessos-remotos-USUARIO-PC-data.txt`n`n" +
                "O TXT pode ser colado em qualquer IA - ele carrega as instrucoes e um`n" +
                "bloco [DADOS-JSON] dentro, alem da secao [COBERTURA-E-LIMITES] que diz`n" +
                "o que a varredura NAO consegue provar.`n`n" +
                "Se der ACHADO: nao desinstalar e nao apagar nada - a maquina e prova.")
    Set-Status "Rastreador lancado em nova janela" ([System.Drawing.Color]::DarkGreen)
}

function Exec-NetOpt {
    $did = @()
    if ($script:ctx.optPower.Checked) {
        $n = 0
        Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -like '*802.11*' } | ForEach-Object {
            try {
                $pm = Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction Stop
                $pm.AllowComputerToTurnOffDevice = 'Disabled'
                $pm | Set-NetAdapterPowerManagement -ErrorAction Stop
                $n++
            } catch {}
        }
        $did += "Economia de energia desligada em $n placa(s) WiFi"
    }
    if ($script:ctx.optDnsFlush.Checked) {
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        $did += "Cache DNS limpo"
    }
    if ($script:ctx.optDnsSet.Checked) {
        if (Confirm-Action "Definir DNS 8.8.8.8 / 1.1.1.1 nos adaptadores ativos?`n`nNAO use em PC corporativo com DNS interno (pode quebrar acesso a sistemas da empresa).") {
            Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
                Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ('8.8.8.8', '1.1.1.1') -ErrorAction SilentlyContinue
            }
            $did += "DNS definido para 8.8.8.8 / 1.1.1.1"
        }
    }

    $out  = "=== Otimizacao de rede ===`n`n>> O que foi feito:`n"
    if ($did.Count -gt 0) { foreach ($x in $did) { $out += "   - $x`n" } } else { $out += "   (nada marcado)`n" }
    $out += "`nDica: rode o 'Diagnostico de conexao' de novo pra comparar."
    Set-Output $out
    Set-Status "Otimizacao de rede concluida" ([System.Drawing.Color]::DarkGreen)
}

# --- PARTICAO ---
function Exec-Wipe {
    $sel = $script:ctx.disk.SelectedItem
    if (-not $sel) { Show-Msg "Selecione um disco." 'Aviso' 'Warning'; return }
    $label = $script:ctx.label.Text.Trim()
    if (-not $label) { $label = "HDD" }

    if ($sel.Number -eq (Get-SystemDiskNumber)) {
        Show-Msg "BLOQUEADO: disco do sistema." 'Erro' 'Error'; return
    }

    $secure = $false
    if ($script:ctx.secure) { $secure = $script:ctx.secure.Checked }
    $phys = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $sel.Number }
    $media = if ($phys) { "$($phys.MediaType)" } else { '' }

    # Formatacao segura (zeragem) so vale pra HD
    if ($secure -and $media -ne 'HDD') {
        Show-Msg "Formatacao segura (zeragem de setores) so funciona em HD.`n`nEste disco e '$media'. Em SSD/NVMe sobrescrever NAO garante apagamento (wear leveling) - use o secure erase do fabricante.`n`nDesmarque 'Formatacao segura' pra formatar normal." 'Aviso' 'Warning'
        return
    }

    $confirmExtra = if ($secure) { "`n`nMODO SEGURO: vai ZERAR todos os setores (diskpart clean all).`nPode levar HORAS num HD grande." } else { "" }
    if (-not (Confirm-Action "Apagar TUDO no Disk $($sel.Number) e formatar como NTFS '$label'?$confirmExtra`n`nIrreversivel.")) { return }

    if ($secure) {
        Set-Status "Zerando todos os setores (diskpart clean all) - pode levar horas..." ([System.Drawing.Color]::DarkOrange)
        $dpScript = "select disk $($sel.Number)`r`nclean all`r`nexit`r`n"
        $dpScript | diskpart | Out-Null
    } else {
        Clear-Disk -Number $sel.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    }

    $d = Get-Disk -Number $sel.Number
    if ($d.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $sel.Number -PartitionStyle GPT -ErrorAction Stop }
    $part = New-Partition -DiskNumber $sel.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    Format-Volume -DriveLetter $part.DriveLetter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null

    $modo = if ($secure) { " (setores zerados)" } else { "" }
    Show-Msg "Disk $($sel.Number) pronto na letra $($part.DriveLetter): como '$label'$modo" "Sucesso"
    Set-Status "Disk $($sel.Number) -> $($part.DriveLetter): NTFS '$label'$modo" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Label {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $newlbl = $script:ctx.label.Text.Trim()
    if (-not $newlbl) { Show-Msg "Digite a nova label." 'Aviso' 'Warning'; return }
    Set-Volume -DriveLetter $sel.Letter -NewFileSystemLabel $newlbl -ErrorAction Stop
    Set-Status "Label do $($sel.Letter): alterada para '$newlbl'" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Letter {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $new = $script:ctx.newletter.Text.Trim().ToUpper()
    if ($new -notmatch '^[A-Z]$') { Show-Msg "Letra invalida. Use A-Z." 'Aviso' 'Warning'; return }
    $part = Get-Partition -DriveLetter $sel.Letter
    Set-Partition -DriveLetter $sel.Letter -NewDriveLetter $new -ErrorAction Stop
    Set-Status "Letra $($sel.Letter): -> $($new):" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Resize {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $sizeText = $script:ctx.newsize.Text.Trim()
    $part = Get-Partition -DriveLetter $sel.Letter
    if (-not $sizeText) {
        $supp = Get-PartitionSupportedSize -DriveLetter $sel.Letter
        Resize-Partition -DriveLetter $sel.Letter -Size $supp.SizeMax -ErrorAction Stop
        Set-Status "Volume $($sel.Letter): redimensionado pro maximo possivel" ([System.Drawing.Color]::DarkGreen)
    } else {
        $newSize = [int64]([double]$sizeText * 1GB)
        Resize-Partition -DriveLetter $sel.Letter -Size $newSize -ErrorAction Stop
        Set-Status "Volume $($sel.Letter): redimensionado para $sizeText GB" ([System.Drawing.Color]::DarkGreen)
    }
}

function Exec-Format {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $fs = $script:ctx.fs.SelectedItem
    $label = $script:ctx.label.Text.Trim()
    if (-not (Confirm-Action "Formatar $($sel.Letter): como $fs com label '$label'?`n`nApaga todos os dados.")) { return }
    Format-Volume -DriveLetter $sel.Letter -FileSystem $fs -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null
    Set-Status "$($sel.Letter): formatado como $fs '$label'" ([System.Drawing.Color]::DarkGreen)
}

# --- MANUTENCAO ---
function Show-ChkdskSchedule {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $txt = (cmd /c "chkntfs $($sel.Letter):" 2>&1 | Out-String).Trim()
    Set-Output ("=== Agendamento CHKDSK - $($sel.Letter): ===`n`n$txt`n`n(Se nao mencionar agendamento/'schedule', nao ha CHKDSK marcado pro proximo boot.)")
    Set-Status "Agendamento consultado ($($sel.Letter):)" ([System.Drawing.Color]::DarkGreen)
}

function Cancel-ChkdskSchedule {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    if (-not (Confirm-Action "Cancelar qualquer CHKDSK agendado pra $($sel.Letter): no proximo boot?")) { return }
    $txt = (cmd /c "chkntfs /x $($sel.Letter):" 2>&1 | Out-String).Trim()
    Set-Output ("=== Cancelar agendamento - $($sel.Letter): ===`n`nComando: chkntfs /x $($sel.Letter):`n$txt`n`nAgendamento cancelado (se existia).")
    Set-Status "Agendamento cancelado ($($sel.Letter):)" ([System.Drawing.Color]::DarkGreen)
}

function Invoke-StepProc($exe, $argList, $label, $stepNum, $stepTotal) {
    # Roda dism/sfc mostrando progresso AO VIVO no rodape: "Passo X/N: <label> (NN% ou Xs)".
    # Le a saida redirecionada em arquivo (sem travar a UI) e extrai a ultima % que aparecer.
    # Se nao houver %, mostra os segundos decorridos como prova de que esta avancando.
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru -NoNewWindow `
                    -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
    } catch {
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
        return @{ Output = "ERRO ao iniciar $exe : $($_.Exception.Message)"; Code = -1 }
    }
    $start = Get-Date
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 700
        $pct = $null
        try {
            $fs = [System.IO.File]::Open($tmpOut, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs)
            $txt = ($sr.ReadToEnd() -replace "`0", "")
            $sr.Close(); $fs.Close()
            $mm = [regex]::Matches($txt, '(\d+(?:[.,]\d+)?)\s*%')
            if ($mm.Count -gt 0) { $pct = $mm[$mm.Count - 1].Groups[1].Value }
        } catch { }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $prog = if ($pct) { "$pct%" } else { "${elapsed}s" }
        Set-Status "Passo $stepNum/${stepTotal}: $label ($prog)" ([System.Drawing.Color]::DarkOrange)
        [System.Windows.Forms.Application]::DoEvents()
    }
    $proc.WaitForExit()
    $out = ''; $er = ''
    try { $out = ([System.IO.File]::ReadAllText($tmpOut) -replace "`0", "") } catch { }
    try { $er  = ([System.IO.File]::ReadAllText($tmpErr) -replace "`0", "") } catch { }
    Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    if ($er.Trim()) { $out = "$out`n[stderr]`n$er" }
    return @{ Output = $out; Code = $proc.ExitCode }
}

function Get-SrtTrailSummary {
    # Le o log do Reparo de Inicializacao e tenta extrair a causa raiz (PT/ES/EN)
    $path = Join-Path $env:SystemRoot 'System32\Logfiles\Srt\SrtTrail.txt'
    if (-not (Test-Path $path)) { return $null }
    try { $raw = Get-Content $path -Raw -ErrorAction Stop } catch { return $null }
    $lines = $raw -split "`r?`n"
    $cause = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -imatch 'root cause|causa raiz|causa principal') {
            for ($j = $i + 1; $j -lt [Math]::Min($i + 6, $lines.Count); $j++) {
                $t = $lines[$j].Trim()
                if ($t -and $t -notmatch '^[-=]+$') { $cause = $t; break }
            }
            break
        }
    }
    $tail = ($lines | Select-Object -Last 30) -join "`r`n"
    return @{ Path = $path; Cause = $cause; Tail = $tail }
}

function Exec-RepairBoot {
    # Reparo ONLINE do sistema (Windows aberto): DISM + SFC + leitura do SrtTrail.
    # Gera um .log no Desktop cuja PRIMEIRA LINHA e o resultado do SFC + o que falta.
    $doDism = if ($script:ctx.dism) { $script:ctx.dism.Checked } else { $true }
    $doSfc  = if ($script:ctx.sfc)  { $script:ctx.sfc.Checked }  else { $true }
    $doSrt  = if ($script:ctx.srt)  { $script:ctx.srt.Checked }  else { $true }

    $det = ""                       # saida completa (detalhes)
    $sfcResult   = 'N/D'
    $nextStep    = ''
    $dismVerdict = 'nao executado'

    # ---- monta a lista de passos (pra mostrar "Passo X/N" no rodape) ----
    $dismStages = @('CheckHealth','RestoreHealth')
    $steps = @()
    if ($doDism) { foreach ($s in $dismStages) { $steps += "DISM /$s" } }
    if ($doSfc)  { $steps += 'SFC /scannow' }
    if ($doSrt)  { $steps += 'Ler SrtTrail.txt' }
    $steps += 'Salvar log'
    $total = $steps.Count
    $stepN = 0

    # ---- DISM (CheckHealth rapido + RestoreHealth conserta) ----
    if ($doDism) {
        $det += "===== DISM (integridade da imagem) =====`n`n"
        foreach ($stage in $dismStages) {
            $stepN++
            $r = Invoke-StepProc 'dism.exe' @('/Online','/Cleanup-Image',"/$stage") "DISM /$stage" $stepN $total
            $det += ">> DISM /$stage  (exit $($r.Code))`n$($r.Output.Trim())`n`n"
            if ($stage -eq 'RestoreHealth') {
                $dismVerdict = switch ($r.Code) {
                    0       { 'imagem OK / restaurada com sucesso' }
                    3010    { 'restaurada (requer reiniciar)' }
                    default { "ERRO (exit $($r.Code)) - sem internet? use fonte install.wim (/Source)" }
                }
            }
        }
    } else {
        $det += "===== DISM ===== (pulado pelo usuario)`n`n"
    }

    # ---- SFC ----
    if ($doSfc) {
        $stepN++
        $r = Invoke-StepProc 'sfc.exe' @('/scannow') 'SFC /scannow' $stepN $total
        $sfcClean = ($r.Output -replace "`0", "").Trim()   # sfc redirecionado vem com NUL entre chars
        $det += "===== SFC /scannow =====`n$sfcClean`n`n"

        # Veredito por texto (multi-idioma PT/ES/EN). Ordem importa: checar falhas antes de sucesso.
        if ($sfcClean -imatch 'unable to fix|n[aã]o conseguiu corrigir|no pudo reparar') {
            $sfcResult = 'ACHOU corrompidos e NAO corrigiu todos'
            $nextStep  = 'FALTA: rodar OFFLINE no WinRE -> sfc /scannow /offbootdir=C:\ /offwindir=C:\Windows (e DISM /Image). Me envie o log.'
        } elseif ($sfcClean -imatch 'could not perform|n[aã]o p[oô]de executar|no pudo realizar') {
            $sfcResult = 'SFC NAO RODOU (operacao pendente)'
            $nextStep  = 'FALTA: reiniciar e rodar de novo; se insistir, rodar OFFLINE no WinRE.'
        } elseif ($sfcClean -imatch 'successfully repaired|repaired them|os reparou|reparou|repar[oó]') {
            $sfcResult = 'ACHOU corrompidos e REPAROU com exito'
            $nextStep  = 'PROXIMO: reiniciar e testar o boot. Se ainda falhar -> WinRE (bootrec / bcdboot).'
        } elseif ($sfcClean -imatch 'did not find|n[aã]o encontrou|no encontr[oó]') {
            $sfcResult = 'NENHUMA violacao (arquivos do sistema OK)'
            $nextStep  = 'PROXIMO: se ainda nao boota, o problema e o BCD/boot (nao os arquivos) -> WinRE: bootrec /rebuildbcd e bcdboot C:\Windows.'
        } else {
            $sfcResult = 'INDETERMINADO (ver saida completa)'
            $nextStep  = 'Me envie este log pra eu interpretar.'
        }
    } else {
        $sfcResult = 'SFC pulado pelo usuario'
        $det += "===== SFC ===== (pulado)`n`n"
    }

    # ---- SrtTrail (causa da tela "nao foi possivel reparar") ----
    if ($doSrt) {
        $stepN++
        Set-Status "Passo $stepN/${total}: lendo SrtTrail.txt..." ([System.Drawing.Color]::DarkOrange)
        [System.Windows.Forms.Application]::DoEvents()
        $srt = Get-SrtTrailSummary
        $det += "===== SrtTrail.txt (log do Reparo de Inicializacao) =====`n"
        if ($srt) {
            $det += "Arquivo: $($srt.Path)`n"
            if ($srt.Cause) { $det += "CAUSA RAIZ detectada: $($srt.Cause)`n" }
            $det += "--- ultimas linhas ---`n$($srt.Tail)`n"
        } else {
            $det += "(nao encontrado - o Reparo de Inicializacao pode nunca ter rodado, ou a letra do disco difere)`n"
        }
        $det += "`n"
    }

    # ---- monta o LOG: 1a linha = resultado SFC + o que falta ----
    $head = "SFC: $sfcResult"
    if ($nextStep) { $head += "  ||  $nextStep" }
    $osCap = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { 'N/D' }
    $meta  = "DISM: $dismVerdict`n" +
             "Quando: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  |  PC: $env:COMPUTERNAME  |  $osCap`n" +
             ('=' * 72)
    $logText = "$head`n$meta`n`n$det"

    # ---- salva no Desktop pra enviar ----
    $stepN++
    Set-Status "Passo $stepN/${total}: salvando log..." ([System.Drawing.Color]::DarkOrange)
    [System.Windows.Forms.Application]::DoEvents()
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path (Get-PastaBackup) "reparo-boot-$stamp.log"
    try {
        $logText | Out-File -FilePath $logPath -Encoding UTF8 -ErrorAction Stop
        $script:lastRepairLog = $logPath
        $saveMsg = "Log salvo em: $logPath"
    } catch {
        $script:lastRepairLog = $null
        $saveMsg = "NAO consegui salvar o log automaticamente: $($_.Exception.Message)"
    }

    # ---- tela ----
    $screen  = "=== REPARO DE BOOT / SISTEMA (online) ===`n`n"
    $screen += ">> RESULTADO SFC : $sfcResult`n"
    $screen += ">> DISM          : $dismVerdict`n"
    if ($nextStep) { $screen += ">> FALTA/PROXIMO : $nextStep`n" }
    $screen += "`n$saveMsg`n"
    $screen += "(use o botao 'Abrir pasta do log' e me envie esse arquivo)`n`n"
    $screen += "--- conteudo do log ---`n$logText"
    Set-Output $screen
    Set-Status "Reparo concluido ($stepN/$total) - $sfcResult" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Chkdsk {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $L = $sel.Letter
    $cdArgs = @("${L}:")
    if ($script:ctx.online.Checked) { $cdArgs += "/scan" }
    if ($script:ctx.fix.Checked)    { $cdArgs += "/f" }
    if ($script:ctx.scan.Checked)   { $cdArgs += "/r" }

    Set-Status "Rodando CHKDSK em $L`:..." ([System.Drawing.Color]::DarkOrange)
    # "Y" no stdin responde automaticamente caso o chkdsk pergunte se agenda no boot
    $output = ("Y" | & chkdsk @cdArgs 2>&1 | Out-String)
    $code = $LASTEXITCODE

    # Sistema de arquivos via exit code (independe de idioma)
    $fsTxt = switch ($code) {
        0 { 'sem erros (saudavel)' }
        1 { 'erros encontrados e CORRIGIDOS' }
        2 { 'verificacao pendente - rode com /f (ou agende)' }
        3 { 'nao verificado - sera agendado no proximo boot' }
        default { "codigo $code" }
    }

    # Setores defeituosos: le o numero de KB na linha "defe..."/"bad sector" (PT/ES/EN)
    $badKB = $null
    foreach ($line in ($output -split "`n")) {
        if ($line -imatch 'defe|bad sector') {
            $m = [regex]::Match($line, '([\d.,]+)\s*KB')
            if ($m.Success) { $badKB = [int64]($m.Groups[1].Value -replace '[.,]', ''); break }
        }
    }
    $badTxt = if ($null -eq $badKB) { 'N/D' }
              elseif ($badKB -gt 0)  { "$badKB KB - PERIGO: falha fisica, faca BACKUP" }
              else                   { '0 (nenhum - sem falha fisica)' }

    $risco = (($null -ne $badKB) -and ($badKB -gt 0)) -or ($code -ge 2)
    $ver = if ($risco) { 'ATENCAO - ver detalhes / backup' }
           elseif ($code -le 1) { 'OK - nada a fazer' }
           else { 'verificar' }

    $out  = "=== CHKDSK - $L`: ===`n`n"
    $out += ">> Interpretacao (resumo):`n"
    $out += "   Sistema de arquivos : $fsTxt`n"
    $out += "   Setores defeituosos : $badTxt`n"
    $out += "   VEREDITO            : $ver`n"
    $out += "`n(comando: chkdsk $($cdArgs -join ' '))`n"
    $out += "`n--- saida completa (copie pra uma IA se quiser interpretar) ---`n"
    $out += $output
    Set-Output $out
    Set-Status "CHKDSK $L`: concluido (codigo $code)" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Defrag {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $L = $sel.Letter
    $media = Get-VolumeMediaType $L

    $freeBefore = (Get-Volume -DriveLetter $L -ErrorAction SilentlyContinue).SizeRemaining
    $fragBefore = $null; $fragAfter = $null
    if ($media -eq 'HDD') {
        Set-Status "Analisando fragmentacao de $L`:..." ([System.Drawing.Color]::DarkOrange)
        $fragBefore = Get-FragPct $L
    }

    Set-Status "Otimizando $L`: (pode demorar)..." ([System.Drawing.Color]::DarkOrange)
    Optimize-Volume -DriveLetter $L -Verbose -ErrorAction Stop 4>&1 | Out-Null

    if ($media -eq 'HDD') { $fragAfter = Get-FragPct $L }
    $freeAfter = (Get-Volume -DriveLetter $L -ErrorAction SilentlyContinue).SizeRemaining

    # --- Monta resumo ---
    $out = "=== Resumo da otimizacao - $L`: ===`n`n"
    $out += "Tipo de disco  : $media`n"

    if ($media -eq 'HDD') {
        $out += "Operacao       : Desfragmentacao`n"
        $bStr = if ($null -ne $fragBefore) { "$fragBefore%" } else { 'N/D' }
        $aStr = if ($null -ne $fragAfter)  { "$fragAfter%" }  else { 'N/D' }
        $out += "Fragmentacao   : $bStr -> $aStr`n"
    } else {
        $tipoOp = if ($media -eq 'SSD') { 'TRIM/Retrim executado' } else { 'Otimizacao executada' }
        $out += "Operacao       : $tipoOp`n"
    }

    if ($null -ne $freeBefore -and $null -ne $freeAfter) {
        $out += "Espaco livre   : $(Format-Bytes $freeBefore) -> $(Format-Bytes $freeAfter)`n"
    }

    # --- Veredito ---
    $verdict = ''
    if ($media -eq 'HDD' -and $null -ne $fragBefore -and $null -ne $fragAfter) {
        $drop = $fragBefore - $fragAfter
        if ($fragBefore -lt 5)      { $verdict = "= Ja estava otimizado (fragmentacao < 5%)" }
        elseif ($drop -ge 10)       { $verdict = "OK - Sucesso (caiu $drop pontos de fragmentacao)" }
        elseif ($drop -gt 0)        { $verdict = "~ Moderado (caiu $drop pontos)" }
        else                        { $verdict = "= Sem mudanca relevante" }
    } elseif ($media -eq 'SSD') {
        $verdict = "OK - TRIM concluido (no SSD o ganho e interno, nao ha fragmentacao a medir)"
    } else {
        $verdict = "OK - Otimizacao concluida"
    }
    $out += "Resultado      : $verdict`n"

    Set-Output $out
    Set-Status "Otimizacao concluida em $L`:" ([System.Drawing.Color]::DarkGreen)
}

function Exec-WipeFree {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    if (-not (Confirm-Action "Sobrescrever espaco livre de $($sel.Letter): com zeros?`n`nPode demorar bastante.")) { return }
    $output = cipher /w:"$($sel.Letter):\" 2>&1 | Out-String
    $script:ctx.output.Text = $output
    Set-Status "Espaco livre limpo em $($sel.Letter):" ([System.Drawing.Color]::DarkGreen)
}

# --- BACKUP ---
function Exec-BackupUser {
    $dst = $script:ctx.dest.SelectedItem; if (-not $dst) { return }
    $profiles = @($script:ctx.profiles.CheckedItems)
    if (-not $profiles) { Show-Msg "Marque ao menos um perfil." 'Aviso' 'Warning'; return }

    $folders = @{}
    if ($script:ctx.fDesktop.Checked) { $folders['Desktop'] = 'Desktop' }
    if ($script:ctx.fDocs.Checked)    { $folders['Documents'] = 'Documentos' }
    if ($script:ctx.fPics.Checked)    { $folders['Pictures'] = 'Imagens' }
    if ($script:ctx.fVids.Checked)    { $folders['Videos'] = 'Videos' }
    if ($script:ctx.fMusic.Checked)   { $folders['Music'] = 'Musica' }
    if ($script:ctx.fDown.Checked)    { $folders['Downloads'] = 'Downloads' }
    if ($script:ctx.fAppData.Checked) { $folders['AppData\Roaming'] = 'AppData' }
    if ($script:ctx.fFavs.Checked)    { $folders['Favorites'] = 'Favoritos' }

    $baseDest = "$($dst.Letter):\Backup_$(Get-Date -Format yyyy-MM-dd_HHmm)"
    New-Item -ItemType Directory -Path $baseDest -Force | Out-Null

    foreach ($p in $profiles) {
        foreach ($k in $folders.Keys) {
            $src = "C:\Users\$p\$k"
            $dest = "$baseDest\$p\$($folders[$k])"
            if (Test-Path $src) {
                Set-Status "Copiando $p\$k ..." ([System.Drawing.Color]::DarkOrange)
                & robocopy $src $dest /E /MT:8 /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
            }
        }
    }

    Show-Msg "Backup concluido em:`n$baseDest" "Sucesso"
    Set-Status "Backup concluido em $baseDest" ([System.Drawing.Color]::DarkGreen)
}

function Exec-CloneData {
    $src = $script:ctx.src.SelectedItem
    $dst = $script:ctx.dst.SelectedItem
    if (-not $src -or -not $dst) { return }
    if ($src.Letter -eq $dst.Letter) { Show-Msg "Origem e destino sao iguais." 'Aviso' 'Warning'; return }
    if ($src.Letter -eq 'C') { Show-Msg "Nao da pra clonar C: a quente. Use a opcao VHDX." 'Aviso' 'Warning'; return }

    $rcArgs = @("$($src.Letter):\", "$($dst.Letter):\", "/E", "/MT:8", "/R:1", "/W:1")
    if ($script:ctx.mirror.Checked) { $rcArgs[2] = "/MIR" }

    if (-not (Confirm-Action "Copiar tudo de $($src.Letter): para $($dst.Letter):?")) { return }
    & robocopy @rcArgs | Out-Null
    Show-Msg "Clone concluido." "Sucesso"
    Set-Status "$($src.Letter): -> $($dst.Letter): concluido" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Vhdx {
    $dst = $script:ctx.dst.SelectedItem; if (-not $dst) { return }
    $tool = "$env:TEMP\disk2vhd.exe"
    if (-not (Test-Path $tool)) {
        Set-Status "Baixando Disk2VHD..." ([System.Drawing.Color]::DarkOrange)
        Invoke-WebRequest "https://live.sysinternals.com/disk2vhd.exe" -OutFile $tool -UseBasicParsing
    }
    $outFile = "$($dst.Letter):\C_snapshot_$(Get-Date -Format yyyy-MM-dd_HHmm).vhdx"
    if (-not (Confirm-Action "Criar VHDX do C: em '$outFile'?`n`nPode demorar (depende do uso de C:).")) { return }
    & $tool /accepteula -c C: $outFile | Out-Null
    Show-Msg "Snapshot criado em:`n$outFile" "Sucesso"
    Set-Status "VHDX criada em $outFile" ([System.Drawing.Color]::DarkGreen)
}

# --- USUARIOS ---
function Exec-DeleteUser {
    $sel = $script:ctx.profiles.SelectedItems
    if (-not $sel -or $sel.Count -eq 0) { Show-Msg "Selecione um perfil." 'Aviso' 'Warning'; return }
    $item = $sel[0]
    $name = $item.Text
    $path = $item.Tag
    $status = $item.SubItems[3].Text

    if ($name -in @('Administrator','DefaultAccount','Guest','WDAGUtilityAccount')) {
        Show-Msg "Perfil de sistema, nao remova." 'Aviso' 'Warning'; return
    }

    # Bloqueia auto-delete (nao pode apagar o proprio usuario logado)
    $currentUser = "$env:USERNAME"
    if ($name -eq $currentUser) {
        Show-Msg "Voce esta logado nessa conta agora. Faca logoff e use outra conta admin pra apagar essa." 'Aviso' 'Warning'
        return
    }

    $isLoggedIn = ($status -eq "EM USO")
    $extraMsg = if ($isLoggedIn) { "`n`nATENCAO: O usuario esta LOGADO agora. Vai ser deslogado automaticamente antes de apagar." } else { "" }

    if (-not (Confirm-Action "Apagar perfil '$name' completamente?$extraMsg`n`nIsso remove:`n - Pasta $path`n - Conta de usuario local`n - Entradas no registro`n`nIrreversivel.")) { return }

    # Captura SID antes (pra usar em unload de registry depois se precisar)
    $userSid = $null
    try { $userSid = (Get-LocalUser -Name $name -ErrorAction SilentlyContinue).SID.Value } catch {}

    # 0. Se logado, desconectar + fazer logoff forçado + matar processos
    if ($isLoggedIn) {
        Set-Status "Desconectando e deslogando '$name'..." ([System.Drawing.Color]::DarkOrange)
        try {
            Disconnect-UserSession $name $userSid
        } catch {
            Show-Msg "Erro ao desconectar '$name': $($_.Exception.Message)" 'Erro' 'Error'
            return
        }
    }

    # 1. Tenta API nativa DeleteProfile (userenv.dll) - eh o que Computer Management usa
    # Mais robusto que Remove-CimInstance pra casos com profile loaded ou hive preso
    $profileDeleted = $false
    $lastError = $null

    if ($userSid) {
        try {
            $deleteProfileSig = '[DllImport("userenv.dll", CharSet=CharSet.Auto, SetLastError=true)] public static extern int DeleteProfile(string sidString, string profilePath, string computerName);'
            $delHelper = Add-Type -MemberDefinition $deleteProfileSig -Name "ProfileUtil" -Namespace "Win32" -PassThru -ErrorAction Stop
            $result = $delHelper::DeleteProfile($userSid, $null, $null)
            if ($result -ne 0) {
                $profileDeleted = $true
            }
        } catch {
            $lastError = $_.Exception.Message
        }
    }

    # 2. Se DeleteProfile falhou, fallback pro Remove-CimInstance com retries
    if (-not $profileDeleted) {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $profile = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -eq $path }
                if (-not $profile) { $profileDeleted = $true; break }
                $profile | Remove-CimInstance -ErrorAction Stop
                $profileDeleted = $true
                break
            } catch {
                $lastError = $_.Exception.Message
                Set-Status "Tentativa $attempt/5 (profile preso)..." ([System.Drawing.Color]::DarkOrange)
                taskkill /F /FI "USERNAME eq $name" 2>&1 | Out-Null
                if ($userSid) { reg unload "HKU\$userSid" 2>&1 | Out-Null }
                Start-Sleep -Seconds 3
            }
        }
    }

    # 3. Remove a conta de usuario (mesmo se o profile nao saiu, conseguir tirar a conta ja resolve metade)
    $accountRemoved = $false
    try {
        Remove-LocalUser -Name $name -ErrorAction Stop
        $accountRemoved = $true
    } catch {
        if (-not $lastError) { $lastError = $_.Exception.Message }
    }

    # 4. Forca remocao da pasta via rmdir (mais permissivo que Remove-Item)
    $folderRemoved = $false
    if (Test-Path $path) {
        # Primeiro tenta Remove-Item
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $path)) { $folderRemoved = $true }
        else {
            # Fallback: rmdir do cmd.exe que costuma ser mais permissivo
            cmd /c "rmdir /s /q `"$path`"" 2>&1 | Out-Null
            if (-not (Test-Path $path)) { $folderRemoved = $true }
        }
    } else {
        $folderRemoved = $true
    }

    # 5. Relatorio final
    $sufix = if ($isLoggedIn) { " (apos logoff forcado)" } else { "" }
    if ($profileDeleted -and $accountRemoved -and $folderRemoved) {
        Show-Msg "Perfil '$name' apagado$sufix." "Sucesso"
        Set-Status "Perfil $name removido$sufix" ([System.Drawing.Color]::DarkGreen)
    } else {
        $report = @()
        $report += "Profile (Win32_UserProfile): $(if ($profileDeleted) {'OK'} else {'FALHOU'})"
        $report += "Conta de usuario: $(if ($accountRemoved) {'OK'} else {'FALHOU'})"
        $report += "Pasta $($path): $(if ($folderRemoved) {'OK'} else {"FALHOU"})"
        if ($lastError) { $report += "`nErro mais recente:`n$lastError" }
        $report += "`n`nDica: reinicie o PC e rode de novo, geralmente resolve o que sobrou."
        Show-Msg ("Remocao parcial:`n`n" + ($report -join "`n")) 'Aviso' 'Warning'
        Set-Status "$name removido parcialmente - ver dialog" ([System.Drawing.Color]::DarkOrange)
    }
    Build-Panel 'users'  # refresh lista
}

# Solta um perfil de usuario que esta logado/preso, na ordem que funciona:
# tsdiscon (corta a sessao sem esperar app) -> logoff -> taskkill -> unload do hive.
# Usado pelo apagar E pelo renomear perfil (logoff sozinho nao solta os handles).
function Disconnect-UserSession($name, $userSid) {
    $userSessions = @()
    $sessions = quser 2>$null
    foreach ($line in $sessions) {
        if ($line -match "^\s*>?\s*(\S+)\s+(?:\S+\s+)?(\d+)\s+(\w+)") {
            $sessUser = $matches[1].TrimStart('>').Trim()
            if ($sessUser -ieq $name) { $userSessions += $matches[2] }
        }
    }

    # ETAPA 1: tsdiscon = desconecta imediato (mesmo que o Task Manager > Disconnect faz).
    # Mais agressivo que logoff: nao espera apps fecharem, so corta a sessao.
    foreach ($sid in $userSessions) { tsdiscon $sid 2>&1 | Out-Null }
    Start-Sleep -Seconds 2

    # ETAPA 2: logoff = encerra a sessao definitivamente
    foreach ($sid in $userSessions) { logoff $sid 2>&1 | Out-Null }
    Start-Sleep -Seconds 2

    # ETAPA 3: matar TODOS os processos restantes
    taskkill /F /FI "USERNAME eq $name" 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # ETAPA 4: descarregar hive de registro
    if ($userSid) {
        reg unload "HKU\$userSid" 2>&1 | Out-Null
        reg unload "HKU\$($userSid)_Classes" 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 1
}

# Renomear a pasta do perfil (C:\Users\xyz).
# Renomear a CONTA nunca renomeia a pasta: quem manda e o ProfileImagePath no
# registro, gravado no primeiro login. A ORDEM aqui e o que importa - pasta
# primeiro, registro so se a pasta saiu. Invertido (ou sem try), da o classico
# "pasta antiga + registro novo" = perfil temporario no proximo login.
function Exec-RenameUser {
    $sel = $script:ctx.profiles.SelectedItems
    if (-not $sel -or $sel.Count -eq 0) { Show-Msg "Selecione um perfil." 'Aviso' 'Warning'; return }
    $item = $sel[0]
    $info = $item.Tag
    $oldFolder = $item.Text
    $new = $script:ctx.newname.Text.Trim()
    $renameAccount = $script:ctx.alsoAccount.Checked
    $makeJunction  = $script:ctx.junction.Checked

    $usersRoot = Split-Path $info.RegPath -Parent   # normalmente C:\Users
    $newPath   = Join-Path $usersRoot $new

    # --- validacoes ---
    if (-not $new) { Show-Msg "Digite o novo nome da pasta." 'Aviso' 'Warning'; return }
    if ($new -match '[\\/:*?"<>|]' -or $new -match '\s') {
        Show-Msg "Nome invalido (sem espacos nem \ / : * ? `" < > |)." 'Aviso' 'Warning'; return
    }
    if ($new -ieq $oldFolder) { Show-Msg "O nome novo e igual ao atual." 'Aviso' 'Warning'; return }
    if ($oldFolder -in @('Administrator','Administrador','Default','Public','DefaultAccount','WDAGUtilityAccount')) {
        Show-Msg "Perfil de sistema, nao renomeie." 'Aviso' 'Warning'; return
    }
    if (Test-Path $newPath) { Show-Msg "Ja existe $newPath. Escolha outro nome." 'Aviso' 'Warning'; return }
    if ($renameAccount -and $info.Account -and $new.Length -gt 20) {
        Show-Msg "Conta local do Windows aceita no maximo 20 caracteres. Encurte o nome ou desmarque 'Renomear tambem a conta local'." 'Aviso' 'Warning'; return
    }

    # Nao da pra renomear o perfil em que voce esta logado (arquivos em uso o tempo todo)
    if ($info.RegPath -ieq $env:USERPROFILE) {
        Show-Msg "Esse e o perfil em que voce esta logado agora. Faca logoff e rode isto por outra conta admin." 'Aviso' 'Warning'; return
    }

    # --- origem em disco: normalmente a pasta do registro; se o registro estiver
    # apontando pro vazio (tentativa anterior pela metade), tenta a pasta orfa ---
    $srcPath = $info.RegPath
    $fixMsg  = ""
    if (-not $info.OnDisk) {
        $known  = @(Get-CimInstance Win32_UserProfile | ForEach-Object { Split-Path $_.LocalPath -Leaf })
        $known += @('Default','Default User','Public','All Users','Todos os Usuarios','Usuario Padrao')
        $orphans = @(Get-ChildItem $usersRoot -Force -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notin $known })
        if ($orphans.Count -eq 1) {
            $srcPath = $orphans[0].FullName
            $fixMsg  = "`n`nATENCAO: o registro aponta pra $($info.RegPath), que NAO existe (operacao anterior pela metade). Vou usar a pasta orfa $srcPath como origem e reconciliar o registro."
        } else {
            Show-Msg ("O registro desse perfil aponta pra $($info.RegPath), que nao existe, e nao deu pra adivinhar qual pasta de $usersRoot pertence a ele ($($orphans.Count) candidatas).`n`nRenomeie a pasta certa na mao pra '$new' e depois ajuste o ProfileImagePath do SID $($info.Sid).") 'Aviso' 'Warning'
            return
        }
    }

    # --- confirmacao ---
    $plan = @()
    $plan += " - Pasta: $srcPath  ->  $newPath"
    if ($renameAccount -and $info.Account) { $plan += " - Conta local: $($info.Account)  ->  $new" }
    elseif ($renameAccount -and -not $info.Account) { $plan += " - Conta local: nenhuma encontrada pro SID (nada a renomear)" }
    $plan += " - Registro: ProfileImagePath do SID $($info.Sid)  ->  $newPath"
    if ($makeJunction) { $plan += " - Atalho (junction): $srcPath aponta pro nome novo" }
    if ($info.Loaded)  { $plan += "`nO perfil esta EM USO: vai levar logoff forcado antes." }

    if (-not (Confirm-Action ("Renomear o perfil '$oldFolder' pra '$new'?$fixMsg`n`n" + ($plan -join "`n") + "`n`nDepois REINICIE o PC antes de logar nesse perfil.`n`nContinuar?"))) { return }

    # --- 0. soltar o perfil se estiver logado ---
    if ($info.Loaded) {
        Set-Status "Deslogando '$oldFolder'..." ([System.Drawing.Color]::DarkOrange)
        try { Disconnect-UserSession $(if ($info.Account) { $info.Account } else { $oldFolder }) $info.Sid }
        catch { Show-Msg "Erro ao deslogar: $($_.Exception.Message)" 'Erro' 'Error'; return }
    }

    # --- 1. a pasta PRIMEIRO: e o passo que pode travar. Se travar, PARA AQUI -
    # registro e conta ficam intactos e o perfil continua utilizavel ---
    Set-Status "Renomeando pasta..." ([System.Drawing.Color]::DarkOrange)
    try {
        Rename-Item -LiteralPath $srcPath -NewName $new -ErrorAction Stop
    } catch {
        Set-Status "Pasta travada - nada foi alterado" ([System.Drawing.Color]::DarkRed)
        Show-Msg ("Nao deu pra renomear a pasta - NADA foi alterado (registro e conta intactos, perfil segue funcionando):`n`n$($_.Exception.Message)`n`nQuase sempre e handle preso de processo do perfil. REINICIE o PC, logue nesta conta admin e rode de novo - logo apos o boot a pasta sai livre.") 'Aviso' 'Warning'
        Build-Panel 'renameuser'
        return
    }

    # --- 2. conta local (cosmetico: o perfil e ligado pelo SID, nao pelo nome) ---
    $accountMsg = "nao aplicavel"
    if ($renameAccount -and $info.Account) {
        if ($info.Account -ieq $new) { $accountMsg = "ja era '$new'" }
        else {
            try { Rename-LocalUser -Name $info.Account -NewName $new -ErrorAction Stop; $accountMsg = "$($info.Account) -> $new" }
            catch { $accountMsg = "FALHOU ($($_.Exception.Message))" }
        }
    }

    # --- 3. registro: agora sim, a pasta existe com o nome novo ---
    $regOk = $false
    $regErr = $null
    try {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($info.Sid)" `
                         -Name ProfileImagePath -Value $newPath -ErrorAction Stop
        $regOk = $true
    } catch { $regErr = $_.Exception.Message }

    # Valor solto na chave-mae (sujeira de script que gravou com SID vazio): ali nao existe ProfileImagePath
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" `
                        -Name ProfileImagePath -ErrorAction SilentlyContinue

    # --- 4. junction opcional, pra app com caminho fixo ---
    $juncMsg = ""
    if ($makeJunction) {
        try { New-Item -ItemType Junction -Path $srcPath -Target $newPath -ErrorAction Stop | Out-Null; $juncMsg = "`nAtalho (junction) criado em $srcPath." }
        catch { $juncMsg = "`nAtalho (junction) FALHOU: $($_.Exception.Message)" }
    }

    # --- 5. conferencia pelo registro, nao pelo que a gente acha que gravou ---
    $regNow = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($info.Sid)" -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
    $coerente = ($regOk -and (Test-Path $newPath) -and ($regNow -ieq $newPath))

    if ($coerente) {
        Show-Msg "Perfil renomeado pra '$new'.`n`nPasta: $newPath`nRegistro: $regNow`nConta local: $accountMsg$juncMsg`n`nREINICIE o PC antes de logar nesse perfil." "Sucesso"
        Set-Status "Perfil renomeado pra $new - reiniciar antes de logar" ([System.Drawing.Color]::DarkGreen)
    } else {
        Show-Msg ("ATENCAO - estado INCONSISTENTE, conserte antes de logar em '$new':`n`nPasta $newPath : $(if (Test-Path $newPath) {'OK'} else {'NAO EXISTE'})`nRegistro (SID $($info.Sid)): $(if ($regNow) { $regNow } else { '(vazio)' })`nConta local: $accountMsg$juncMsg`n`n" +
                  "$(if ($regErr) { "Erro no registro:`n$regErr`n`n" })" +
                  "Enquanto pasta e registro nao apontarem pro mesmo lugar, logar nesse perfil cria um perfil TEMPORARIO. Aponte o ProfileImagePath do SID pra pasta que existe de fato.") 'Aviso' 'Warning'
        Set-Status "Renomeacao inconsistente - ver dialog" ([System.Drawing.Color]::DarkRed)
    }
    Build-Panel 'renameuser'  # refresh lista
}

function Exec-CreateUser {
    $username = $script:ctx.username.Text.Trim()
    $password = $script:ctx.password.Text
    $fullname = $script:ctx.fullname.Text.Trim()
    $isAdmin = $script:ctx.admin.Checked
    $noExpire = $script:ctx.noexpire.Checked

    if (-not $username) { Show-Msg "Digite o nome do usuario." 'Aviso' 'Warning'; return }
    if ($username -match '[\\/:*?"<>|\s]') { Show-Msg "Nome de usuario contem caracteres invalidos (espacos ou \ / : * ? `" < > |)." 'Aviso' 'Warning'; return }
    if (-not $password) { Show-Msg "Digite uma senha." 'Aviso' 'Warning'; return }
    if ($password.Length -lt 4) { Show-Msg "Senha muito curta (minimo 4 caracteres recomendado)." 'Aviso' 'Warning'; return }

    if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
        Show-Msg "Usuario '$username' ja existe." 'Aviso' 'Warning'; return
    }

    $confirm = "Criar usuario LOCAL '$username'?`n`n"
    if ($fullname) { $confirm += "Nome completo: $fullname`n" }
    $confirm += "Administrador: $(if ($isAdmin) {'SIM'} else {'Nao'})`n"
    $confirm += "Senha nunca expira: $(if ($noExpire) {'SIM'} else {'Nao'})`n`nContinuar?"
    if (-not (Confirm-Action $confirm)) { return }

    $securePwd = ConvertTo-SecureString $password -AsPlainText -Force

    $newUserArgs = @{
        Name = $username
        Password = $securePwd
        AccountNeverExpires = $true
    }
    if ($fullname) { $newUserArgs.FullName = $fullname }
    if ($noExpire) { $newUserArgs.PasswordNeverExpires = $true }

    New-LocalUser @newUserArgs -ErrorAction Stop | Out-Null

    if ($isAdmin) {
        # Pega o grupo Administradores tanto em ingles quanto em portugues
        $adminGroup = $null
        foreach ($g in 'Administrators','Administradores') {
            if (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue) { $adminGroup = $g; break }
        }
        if (-not $adminGroup) {
            # Fallback via SID (S-1-5-32-544 = Administrators sempre)
            $adminGroup = (Get-LocalGroup | Where-Object { $_.SID.Value -eq 'S-1-5-32-544' }).Name
        }
        Add-LocalGroupMember -Group $adminGroup -Member $username -ErrorAction Stop
    }

    $roleText = if ($isAdmin) { "Administrador" } else { "Usuario padrao" }
    Show-Msg "Usuario '$username' criado com sucesso como $roleText.`n`nConta local, sem vinculo com Microsoft." "Sucesso"
    Set-Status "Usuario '$username' criado ($roleText)" ([System.Drawing.Color]::DarkGreen)
}

# --- REDE ---
function Get-LanIPv4 {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -in 'Dhcp','Manual' -and $_.IPAddress -notmatch '^127\.' -and $_.IPAddress -notmatch '^169\.254\.' } |
        Sort-Object InterfaceMetric |
        Select-Object -First 1
    if ($ip) { return $ip.IPAddress }
    return $null
}

function Exec-Share {
    $path = $script:ctx.folderPath.Text.Trim()
    $shareName = $script:ctx.shareName.Text.Trim()
    $fullAccess = $script:ctx.shareFull.Checked

    # Determinar user/senha conforme o radio
    if ($script:ctx.rbExisting.Checked) {
        $user = if ($script:ctx.cmbExisting.SelectedItem) { $script:ctx.cmbExisting.SelectedItem.ToString() } else { '' }
        $pwd = $script:ctx.pwdExisting.Text
        $modeExisting = $true
    } else {
        $user = $script:ctx.txtNew.Text.Trim()
        $pwd = $script:ctx.pwdNew.Text
        $modeExisting = $false
    }

    if (-not (Test-Path $path -PathType Container)) { Show-Msg "Pasta nao existe: '$path'" 'Erro' 'Error'; return }
    if (-not $shareName) { Show-Msg "Digite o nome do compartilhamento" 'Aviso' 'Warning'; return }
    if ($shareName -match '[\\/:*?"<>|]') { Show-Msg "Nome do compartilhamento contem caracteres invalidos ( \\ / : * ? `" < > | )" 'Aviso' 'Warning'; return }
    if (-not $user) { Show-Msg "Selecione ou digite um usuario." 'Aviso' 'Warning'; return }

    # Share ja existe?
    if (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue) {
        if (-not (Confirm-Action "Ja existe um compartilhamento '$shareName'. Substituir?")) { return }
        Remove-SmbShare -Name $shareName -Force -ErrorAction Stop
    }

    # Usuario: existente ou novo
    $existingUser = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
    if ($modeExisting) {
        if (-not $existingUser) { Show-Msg "Usuario '$user' nao existe (mudou de estado?). Recarrega o painel." 'Erro' 'Error'; return }
        if (-not $pwd) { Show-Msg "Digite a senha do usuario '$user' (vai ser usada por quem conectar pela rede)." 'Aviso' 'Warning'; return }
        # Em modo 'existente', a senha eh so pra exibir no dialog final - nao validamos nem alteramos
    } else {
        if ($existingUser) {
            Show-Msg "Usuario '$user' ja existe. Use a opcao 'Usuario existente'." 'Aviso' 'Warning'; return
        }
        if (-not $pwd) { Show-Msg "Digite uma senha pro novo usuario." 'Aviso' 'Warning'; return }
        $securePwd = ConvertTo-SecureString $pwd -AsPlainText -Force
        New-LocalUser -Name $user -Password $securePwd -AccountNeverExpires -PasswordNeverExpires -ErrorAction Stop | Out-Null
    }

    # Cria o share
    if ($fullAccess) {
        New-SmbShare -Name $shareName -Path $path -FullAccess $user -ErrorAction Stop | Out-Null
    } else {
        New-SmbShare -Name $shareName -Path $path -ReadAccess $user -ErrorAction Stop | Out-Null
    }

    # Permissoes NTFS na pasta (sem isso, share permite mas filesystem bloqueia)
    try {
        $acl = Get-Acl $path
        $rights = if ($fullAccess) { 'Modify' } else { 'ReadAndExecute' }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $user, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow'
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $path -AclObject $acl -ErrorAction Stop
    } catch {
        Write-Host "Aviso: permissao NTFS pode estar incompleta: $($_.Exception.Message)"
    }

    # Abre firewall pra SMB
    foreach ($grp in @("File and Printer Sharing","Compartilhamento de Arquivo e Impressora","Compartilhamento de Arquivos e Impressoras")) {
        Enable-NetFirewallRule -DisplayGroup $grp -ErrorAction SilentlyContinue
    }

    # Forca rede pra Privada (sem isso, firewall bloqueia SMB de fora)
    $publicProfiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -eq 'Public' }
    $profileChanged = $false
    if ($publicProfiles) {
        try {
            $publicProfiles | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop
            $profileChanged = $true
        } catch {}
    }
    $profileWarn = if ($profileChanged) {
        "`n`nA rede ativa foi alterada de PUBLICA pra PRIVADA automaticamente (pra permitir acesso pela rede)."
    } else { "" }

    $ip = Get-LanIPv4
    if (-not $ip) { $ip = "<sem IP detectado>" }
    $uncPath = "\\$ip\$shareName"

    $msg = @"
COMPARTILHAMENTO CRIADO COM SUCESSO

UNC:        $uncPath
IPv4 LAN:   $ip
Pasta:      $path
Usuario:    $user
Senha:      $(if ($pwd) { $pwd } else { '(usuario ja existia - senha nao alterada)' })
Permissao:  $(if ($fullAccess) { 'Leitura e ESCRITA' } else { 'Somente leitura' })

ACESSO DE OUTRAS MAQUINAS WINDOWS:
  Win+R -> $uncPath
  Login -> $user
  Senha -> $(if ($pwd) { $pwd } else { '(a senha do usuario)' })$profileWarn
"@

    Show-Msg $msg "Compartilhamento criado" "Information"
    Set-Status "Share '$shareName' criado: $uncPath (user $user)" ([System.Drawing.Color]::DarkGreen)
}

function Exec-RemoveShare {
    $sel = $script:ctx.sharesList.SelectedItems
    if (-not $sel -or $sel.Count -eq 0) { Show-Msg "Selecione um compartilhamento da lista." 'Aviso' 'Warning'; return }
    $name = $sel[0].Text
    if (-not (Confirm-Action "Remover compartilhamento '$name'?`n`nIsso NAO apaga a pasta nem o usuario, so para de compartilhar pela rede.")) { return }
    Remove-SmbShare -Name $name -Force -ErrorAction Stop
    Show-Msg "Compartilhamento '$name' removido." "OK"
    Set-Status "Share '$name' removido" ([System.Drawing.Color]::DarkGreen)
    Build-Panel 'listshares'  # refresh
}

# ============= Eventos =============
$tree.Add_AfterSelect({
    $node = $tree.SelectedNode
    if (-not $node.Tag) { return }
    $id = $node.Tag
    $action = $actions | Where-Object { $_.Id -eq $id }
    if (-not $action) { return }
    $script:currentAction = $id
    $lblTitle.Text = $action.Name
    $lblDesc.Text = $action.Desc
    $btnExecute.Enabled = $true
    Build-Panel $id
})

$btnExecute.Add_Click({
    if ($script:currentAction) { Execute-Action $script:currentAction }
})

[void]$form.ShowDialog()
