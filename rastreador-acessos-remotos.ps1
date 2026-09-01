# ============================================================================
# RASTREADOR DE ACESSOS REMOTOS — IG Networks / TI
# ----------------------------------------------------------------------------
# O que faz: procura programas de acesso remoto nesta maquina, diz se sao
#   esperados ou nao, confere QUEM ASSINOU cada binario, e gera no Desktop um
#   relatorio que pode ser lido por uma pessoa OU colado em qualquer IA.
#
# PARTE A: vestigios do agente Action1 distribuido em abril/2026 disfarcado de
#          "Adobe_Update_2026" (incidente de 14/08/2026).
# PARTE B: QUALQUER OUTRO acesso remoto/RMM na maquina, classificado em
#          esperado x suspeito.
# PARTE C: higiene (RDP ligado, AnyDesk com senha fixa, servico/tarefa rodando
#          de lugar incomum).
#
# PROCEDENCIA: tudo que as etapas 4, 5 e 6 acharem passa por
#   Get-AuthenticodeSignature. Binario SEM assinatura ou com HashMismatch
#   (alterado depois de assinado) rodando de pasta de usuario/ProgramData e'
#   sinal forte, e nao depende de conhecer o nome da ameaca.
#
# NAO REMOVE NADA e NAO ALTERA CONFIGURACAO. E' so diagnostico — se achar algo,
# a maquina precisa ser preservada como prova.
#
# EXIGE ADMINISTRADOR (desde 01/09/2026): sem elevacao ele mostra como abrir o
# PowerShell como administrador e NAO roda - relatorio parcial vira retrabalho.
# Fala PT / ES / EN conforme o idioma do Windows
# (forcar com:  $env:IGN_IDIOMA = 'ES'  antes de rodar).
#
# ----------------------------------------------------------------------------
# IRMAO GEMEO — este arquivo existe em DOIS repositorios com o MESMO corpo:
#   empresa : igcintra/pc-setup      -> verificar-action1.ps1
#             (NAO RENOMEAR: a URL esta dentro do Doc bilingue do accounting.group@
#              e da descricao do evento trimestral na agenda da Andrea)
#   pessoal : GCintra00/formatei-pc  -> rastreador-acessos-remotos.ps1
# Ao corrigir um, corrigir o outro.
# ----------------------------------------------------------------------------
# Uso:  irm <URL-DESTE-ARQUIVO> | iex
# ============================================================================

$ErrorActionPreference = 'SilentlyContinue'

# ----------------------------------------------------------------------------
# UNICA LINHA QUE DIVERGE ENTRE OS DOIS GEMEOS.
# pc-setup (empresa) usa 'verificacao-seguranca' porque o Tutorial no Google Doc
# do accounting.group@ diz textualmente as pessoas para mandarem o arquivo
# "verificacao-seguranca-seuusuario-SEUPC-<data>.txt". Mudar aqui quebra o tutorial.
# formatei-pc (pessoal) usa 'acessos-remotos'.
# ----------------------------------------------------------------------------
$PREFIXO_RELATORIO = 'acessos-remotos'

# ============================================================================
# IDIOMA
# ============================================================================
function Get-Idioma {
    if ($env:IGN_IDIOMA -match '^(PT|ES|EN)$') { return $env:IGN_IDIOMA.ToUpper() }
    $c = @()
    try { $c += (Get-UICulture).Name } catch {}
    try { $c += (Get-Culture).Name } catch {}
    try { $c += @((Get-CimInstance Win32_OperatingSystem).MUILanguages) } catch {}
    try { $c += (Get-WinSystemLocale).Name } catch {}
    foreach ($x in ($c | Where-Object { $_ })) {
        if ($x -match '^pt') { return 'PT' }
        if ($x -match '^es') { return 'ES' }
    }
    return 'EN'
}
$IDIOMA = Get-Idioma

$STR = @{
 PT = @{
  titulo   = 'RASTREADOR DE ACESSOS REMOTOS - IG Networks'
  intro    = 'Isso leva menos de um minuto e nao altera nada no computador.'
  etapa    = '[{0}/6] {1}'
  e1='Procurando registro do agente...'; e2='Procurando nos programas instalados...'
  e3='Lendo o historico de instalacoes do Windows...'; e4='Verificando se esta em execucao...'
  e5='Procurando o instalador na pasta Downloads...'; e6='Procurando outros programas de acesso remoto...'
  ach_t='ENCONTRAMOS ALGO - AVISE A TI'
  ach_1='NAO desinstale e NAO apague nada.'
  rev_t='NADA DO INCIDENTE - MAS A TI VAI CONFERIR'
  rev_1='O programa do incidente NAO esta nesta maquina.'
  rev_2='Achamos outro programa de acesso remoto que pode ser normal'
  rev_3='(alguem da TI pode ter instalado) - so precisa ser conferido.'
  rev_4='Nao precisa desinstalar nada.'
  lim_t='ESTA MAQUINA ESTA LIMPA'
  lim_1='Nada a fazer. Obrigado pela colaboracao!'
  lim_2='(o relatorio traz algumas observacoes de rotina para a TI)'
  adm_t='PRECISA SER ADMINISTRADOR'
  adm_1='Esta verificacao so e confiavel com privilegio de administrador: sem ele,'
  adm_2='parte do registro e dos servicos fica invisivel e o relatorio sai incompleto.'
  adm_3='NADA foi verificado ainda - nenhum relatorio foi gerado.'
  adm_4='Menu Iniciar > digite PowerShell > botao direito > "Executar como administrador".'
  adm_5='Depois cole de novo o MESMO comando que a TI te mandou.'
  adm_6='Se voce nao tem a senha de administrador, avise a TI - ela roda por voce.'
  manda='Mande para a TI o arquivo que ficou no seu Desktop:'
  salvo='Relatorio salvo em:'
  ia   ='Esse arquivo tambem pode ser colado em qualquer IA - ele ja traz as instrucoes dentro.'
 }
 ES = @{
  titulo   = 'RASTREADOR DE ACCESOS REMOTOS - IG Networks'
  intro    = 'Esto toma menos de un minuto y no cambia nada en la computadora.'
  etapa    = '[{0}/6] {1}'
  e1='Buscando registro del agente...'; e2='Buscando en los programas instalados...'
  e3='Leyendo el historial de instalaciones de Windows...'; e4='Verificando si esta en ejecucion...'
  e5='Buscando el instalador en la carpeta Descargas...'; e6='Buscando otros programas de acceso remoto...'
  ach_t='ENCONTRAMOS ALGO - AVISA A TI'
  ach_1='NO desinstales y NO borres nada.'
  rev_t='NADA DEL INCIDENTE - PERO TI VA A REVISAR'
  rev_1='El programa del incidente NO esta en esta computadora.'
  rev_2='Encontramos otro programa de acceso remoto que puede ser normal'
  rev_3='(alguien de TI pudo haberlo instalado) - solo hay que revisarlo.'
  rev_4='No hace falta desinstalar nada.'
  lim_t='ESTA COMPUTADORA ESTA LIMPIA'
  lim_1='Nada que hacer. Gracias por tu colaboracion!'
  lim_2='(el reporte trae algunas observaciones de rutina para TI)'
  adm_t='HACE FALTA SER ADMINISTRADOR'
  adm_1='Esta verificacion solo es confiable con privilegio de administrador: sin el,'
  adm_2='parte del registro y de los servicios queda invisible y el reporte sale incompleto.'
  adm_3='TODAVIA no se verifico nada - no se genero ningun reporte.'
  adm_4='Menu Inicio > escribe PowerShell > clic derecho > "Ejecutar como administrador".'
  adm_5='Despues pega de nuevo el MISMO comando que TI te envio.'
  adm_6='Si no tienes la contrasena de administrador, avisa a TI - ella lo ejecuta por vos.'
  manda='Envia a TI el archivo que quedo en tu Escritorio:'
  salvo='Reporte guardado en:'
  ia   ='Este archivo tambien se puede pegar en cualquier IA - ya trae las instrucciones dentro.'
 }
 EN = @{
  titulo   = 'REMOTE ACCESS SCANNER - IG Networks'
  intro    = 'This takes less than a minute and changes nothing on the computer.'
  etapa    = '[{0}/6] {1}'
  e1='Looking for the agent registry key...'; e2='Looking through installed programs...'
  e3='Reading the Windows installation history...'; e4='Checking whether it is running...'
  e5='Looking for the installer in the Downloads folder...'; e6='Looking for other remote access programs...'
  ach_t='WE FOUND SOMETHING - TELL IT'
  ach_1='Do NOT uninstall and do NOT delete anything.'
  rev_t='NOTHING FROM THE INCIDENT - BUT IT WILL REVIEW'
  rev_1='The program from the incident is NOT on this machine.'
  rev_2='We found another remote access program that may be normal'
  rev_3='(someone from IT may have installed it) - it just needs a review.'
  rev_4='You do not need to uninstall anything.'
  lim_t='THIS MACHINE IS CLEAN'
  lim_1='Nothing to do. Thanks for your help!'
  lim_2='(the report includes some routine notes for IT)'
  adm_t='ADMINISTRATOR REQUIRED'
  adm_1='This check is only reliable with administrator privilege: without it,'
  adm_2='part of the registry and services stays invisible and the report comes out incomplete.'
  adm_3='NOTHING has been checked yet - no report was generated.'
  adm_4='Start menu > type PowerShell > right-click > "Run as administrator".'
  adm_5='Then paste the SAME command IT sent you again.'
  adm_6='If you do not have the administrator password, tell IT - they can run it for you.'
  manda='Please send IT the file left on your Desktop:'
  salvo='Report saved to:'
  ia   ='This file can also be pasted into any AI - the instructions are inside it.'
 }
}[$IDIOMA]

Write-Host ""
Write-Host ("=" * 57) -ForegroundColor Cyan
Write-Host ("  " + $STR.titulo) -ForegroundColor Cyan
Write-Host ("=" * 57) -ForegroundColor Cyan
Write-Host ""
Write-Host $STR.intro -ForegroundColor Gray
Write-Host ""

# ============================================================================
# CONTADOR DE EXECUCOES  (religado em 01/09/2026 — a gestora pediu o numero)
# ----------------------------------------------------------------------------
# Estava DESLIGADO desde a v3 (20/08). Voltou porque o TXT no Desktop so conta
# quem LEMBRA de mandar o arquivo — e o tutorial diz para mandar somente quando
# o resultado NAO e' verde. Ou seja: quem deu LIMPO era invisivel para a TI.
#
# Manda para o Apps Script v2 (aba 'historico', 1 linha por execucao):
#   script, host, usuario, versao, resultado
# A planilha fica na conta Google PESSOAL do Gabriel — por isso vai nome de
# usuario e nome do PC, e NAO vai nada do conteudo do relatorio (nem achado,
# nem caminho de arquivo, nem assinatura). Só o veredito de uma palavra.
#
# NUNCA pode derrubar a varredura: try/catch proprio (o $ErrorActionPreference
# global NAO pega excecao .NET) + TimeoutSec, e o resultado e' descartado.
# ============================================================================
$CONTADOR_URL = 'https://script.google.com/macros/s/AKfycbxCNI2nrcb-mDEMrSi9cmFfrvPBOT3T3MmwnnmNfWnbisdUqZDay59-eok7tg9p9varRg/exec'

function Contar($resultado) {
    try {
        $q = 'script=rastreador' +
             '&host='     + [uri]::EscapeDataString([string]$env:COMPUTERNAME) +
             '&usuario='  + [uri]::EscapeDataString([string]$env:USERNAME) +
             '&versao='   + [uri]::EscapeDataString('2026-09-01') +
             '&resultado='+ [uri]::EscapeDataString([string]$resultado)
        Invoke-RestMethod -Uri ($CONTADOR_URL + '?' + $q) -TimeoutSec 8 | Out-Null
    } catch { }
}

# ============================================================================
# EXIGENCIA DE ADMINISTRADOR  (decisao do Gabriel, 01/09/2026)
# ----------------------------------------------------------------------------
# Por que EXIGIR em vez de so avisar: em 01/09 as duas maquinas da rodada
# tiveram de ser escaneadas DUAS vezes (a 1a saiu admin=False), e o laudo ficou
# com a ressalva "sem privilegio pode ter ficado coisa invisivel" ate a 2a
# passada. Relatorio sem elevacao gera retrabalho e duvida no veredito.
#
# NAO use #Requires -RunAsAdministrator: ele NAO e' honrado quando o script
# chega por  irm <url> | iex  (nao ha arquivo de script). Tem de ser na mao.
# NAO use exit: em  irm | iex  o exit FECHA a janela do PowerShell e a pessoa
# nao chega a ler a mensagem. return encerra so este script.
# ============================================================================
$EH_ADMIN = $false
try {
    $EH_ADMIN = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $EH_ADMIN = $false }

if (-not $EH_ADMIN) {
    Write-Host ("=" * 57) -ForegroundColor Yellow
    Write-Host ("  " + $STR.adm_t) -ForegroundColor Yellow
    Write-Host ("=" * 57) -ForegroundColor Yellow
    Write-Host ""
    Write-Host $STR.adm_1 -ForegroundColor Gray
    Write-Host $STR.adm_2 -ForegroundColor Gray
    Write-Host $STR.adm_3 -ForegroundColor White
    Write-Host ""
    Write-Host $STR.adm_4 -ForegroundColor Cyan
    Write-Host $STR.adm_5 -ForegroundColor Cyan
    Write-Host ""
    Write-Host $STR.adm_6 -ForegroundColor Gray
    Write-Host ""
    # conta a TENTATIVA: para a gestora, quem tentou e esbarrou no admin tambem
    # e' adesao — e para a TI e' a fila de quem precisa de ajuda para rodar.
    Contar 'sem-admin'
    return
}

function Etapa($n, $texto) { Write-Host ($STR.etapa -f $n, $texto) -ForegroundColor White }

# ============================================================================
# COLETOR DE ACHADOS
#   parte      A=Action1(incidente) | B=outro acesso remoto | C=higiene
#   gravidade  CRITICO | ALTO | MEDIO | INFO
#   acao       o que precisa ser feito (e' isso que a IA vai executar/repassar)
# ============================================================================
$F        = New-Object System.Collections.ArrayList
$limites  = New-Object System.Collections.ArrayList
$guid     = ""

function Add-Achado($id, $parte, $grav, $titulo, $evid, $signif, $acao) {
    [void]$F.Add([pscustomobject]@{
        id          = $id
        parte       = $parte
        gravidade   = $grav
        titulo      = $titulo
        evidencia   = @($evid | Where-Object { $_ })
        significado = $signif
        acao        = $acao
    })
}

# ---- Safe: le um valor sem deixar UMA falha derrubar o bloco inteiro ----
# Aprendido no teste de 20/08/2026: uma unica expressao que lanca excecao dentro
# de um @{...} anula a atribuicao TODA (e $ErrorActionPreference nao pega excecao
# .NET, so erro de cmdlet). Em maquina com WMI quebrado o relatorio saia sem a
# secao [MAQUINA] e com "maquina": null no JSON.
function Safe([scriptblock]$sb, $padrao = 'n/d') {
    try { $v = & $sb ; if ($null -eq $v -or "$v" -eq '') { return $padrao } ; return $v }
    catch { return $padrao }
}

# ---- procedencia: quem assinou o binario ----
# Valid        = assinado e cadeia confiavel
# HashMismatch = assinado MAS ALTERADO depois -> nunca e' normal
# NotSigned    = sem assinatura (aceitavel em ferramenta pequena, ruim em servico)
function Procedencia($caminho) {
    if (-not $caminho) { return $null }
    $p = ([string]$caminho).Trim()
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -match '^"([^"]+)"')      { $p = $matches[1] }
    elseif ($p -match '^(.+?\.exe)') { $p = $matches[1] }
    if ($p -match '\.(cmd|bat|vbs|js|wsf|ps1)$') {
        return [pscustomobject]@{ Caminho = $p; Status = 'ScriptSemAssinatura'; Assinante = '' }
    }
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $s = Get-AuthenticodeSignature -LiteralPath $p
    if (-not $s) { return $null }
    $quem = ''
    if ($s.SignerCertificate) {
        $cn = ($s.SignerCertificate.Subject -split ',' | Where-Object { $_ -match 'CN=' } | Select-Object -First 1)
        $quem = ($cn -replace '.*CN=','').Trim()
    }
    return [pscustomobject]@{ Caminho = $p; Status = [string]$s.Status; Assinante = $quem }
}
function TextoProc($pr) {
    if (-not $pr)                             { return 'assinatura: nao foi possivel conferir' }
    if ($pr.Status -eq 'Valid')               { return "assinatura: VALIDA, assinado por $($pr.Assinante)" }
    if ($pr.Status -eq 'HashMismatch')        { return "assinatura: ALTERADO DEPOIS DE ASSINADO (HashMismatch) - dizia ser $($pr.Assinante)" }
    if ($pr.Status -eq 'NotSigned')           { return 'assinatura: SEM ASSINATURA' }
    if ($pr.Status -eq 'ScriptSemAssinatura') { return 'assinatura: e SCRIPT (.cmd/.bat/.vbs/.ps1) - nao existe assinatura possivel' }
    return "assinatura: com problema ($($pr.Status)) - dizia ser $($pr.Assinante)"
}
function ProcRuim($pr) { if (-not $pr) { return $false } ; return ($pr.Status -ne 'Valid') }

# ============================================================================
# [1] chave de registro do agente
# ============================================================================
Etapa 1 $STR.e1
foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Action1','HKLM:\SOFTWARE\Action1')) {
    if (Test-Path $k) {
        $p = Get-ItemProperty $k
        if ($p.'agent.guid') { $guid = $p.'agent.guid' }
        Add-Achado 'action1-registro' 'A' 'CRITICO' 'Chave de registro do agente Action1 presente' @(
            "chave     = $k",
            "agent.guid = $($p.'agent.guid')",
            "system.id  = $($p.'system.id')"
        ) 'O agente de gerenciamento remoto Action1 foi instalado nesta maquina. Foi o agente usado no incidente de 09/04/2026, distribuido disfarcado de "Adobe_Update_2026". O agent.guid identifica a conta do atacante no fornecedor.' 'ISOLAR a maquina da rede sem desligar (nao apagar nada: e prova). Acionar a TI imediatamente. Rotacionar as credenciais usadas nesta maquina. Levar o agent.guid ao fornecedor Action1 para identificar o dono da conta.'
    }
}

# ============================================================================
# [2] entrada de desinstalacao
# ============================================================================
Etapa 2 $STR.e2
$raizes = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$instalados = @(Get-ItemProperty $raizes | Where-Object { $_.DisplayName })
$instalados | Where-Object { $_.DisplayName -match 'Action1' } | ForEach-Object {
    Add-Achado 'action1-programa' 'A' 'CRITICO' "Action1 consta nos programas instalados: $($_.DisplayName)" @(
        "versao          = $($_.DisplayVersion)",
        "InstallSource   = $($_.InstallSource)",
        "InstallDate     = $($_.InstallDate)   (vem do pacote, pode ser falsa)",
        "SystemComponent = $($_.SystemComponent)"
    ) 'O agente do incidente esta registrado como programa instalado.' 'Mesma acao do achado action1-registro: isolar, preservar, acionar a TI.'
}

# ============================================================================
# [3] log do instalador do Windows (a prova mais confiavel)
# ============================================================================
Etapa 3 $STR.e3
$ev = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='MsiInstaller'}
if ($ev) {
    $hit = $ev | Where-Object { $_.Message -match 'Action1|400F3B96|Adobe_Update' }
    if ($hit) {
        $linhas = @()
        foreach ($h in ($hit | Sort-Object TimeCreated)) {
            $msg = ($h.Message -replace "`r?`n", ' ' -replace '\s+', ' ')
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0,200) }
            $linhas += ("{0}  id={1}  {2}" -f $h.TimeCreated, $h.Id, $msg)
        }
        Add-Achado 'action1-log-instalador' 'A' 'CRITICO' 'O log do Windows Installer registra a instalacao do Action1' $linhas 'Esta e a prova mais confiavel: o log do MsiInstaller registra o que foi instalado mesmo que o programa ja tenha sido removido depois. Antivirus nao ve isso.' 'Preservar o log (nao rodar limpeza de disco nesta maquina). Acionar a TI. A data do evento diz QUANDO a maquina foi comprometida - e o inicio da janela a investigar.'
    }
    $maisAntigo = ($ev | Select-Object -Last 1).TimeCreated
    $maisNovo   = ($ev | Select-Object -First 1).TimeCreated
    [void]$limites.Add("Log do Windows Installer cobre de $maisAntigo a $maisNovo ($($ev.Count) eventos).")
    if ($maisAntigo -gt (Get-Date '2026-04-09')) {
        [void]$limites.Add("ATENCAO: o log comeca DEPOIS de 09/04/2026, a data da leva do incidente. Nesta maquina a etapa 3 NAO consegue provar o passado - 'LIMPO' aqui significa 'nada AGORA', e nao 'nunca teve'.")
    }
} else {
    [void]$limites.Add("Nao foi possivel ler o log do Windows Installer nesta maquina. A etapa 3 (prova historica) nao rodou.")
}

# ============================================================================
# [4] servico e pastas (esta ativo AGORA?)
# ============================================================================
Etapa 4 $STR.e4
$servicos = @(Get-CimInstance Win32_Service)
$servicos | Where-Object { $_.Name -match 'action1' -or $_.PathName -match 'Action1' } | ForEach-Object {
    Add-Achado 'action1-servico' 'A' 'CRITICO' "Servico do Action1 presente: $($_.Name)" @(
        "estado   = $($_.State)",
        "caminho  = $($_.PathName)",
        (TextoProc (Procedencia $_.PathName))
    ) 'Servico instalado significa acesso remoto PERSISTENTE: volta a cada reinicio, sem ninguem aceitar nada.' 'Se o estado for Running, o acesso esta ATIVO agora. Isolar a maquina da rede imediatamente, sem desligar e sem desinstalar.'
}
foreach ($d in @("$env:ProgramFiles\Action1", "${env:ProgramFiles(x86)}\Action1", "$env:ProgramData\Action1")) {
    if (Test-Path $d) {
        $it = Get-ChildItem $d -Recurse -File | Sort-Object CreationTime | Select-Object -First 1
        Add-Achado 'action1-pasta' 'A' 'ALTO' "Pasta do Action1 existe: $d" @(
            "arquivo mais antigo = $($it.CreationTime)  ($($it.Name))"
        ) 'Sobra de instalacao. A data do arquivo mais antigo estima quando o agente chegou.' 'Nao apagar. Reportar a data a TI - ela delimita a janela de investigacao.'
    }
}

# ============================================================================
# [5] instalador na pasta Downloads
# ============================================================================
Etapa 5 $STR.e5
Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads') -File -Filter *.msi |
  Where-Object { $_.Name -match 'action1|adobe|acrobat|reader|update' } | ForEach-Object {
    Add-Achado 'instalador-suspeito-downloads' 'A' 'ALTO' "Instalador com nome suspeito em Downloads: $($_.Name)" @(
        "tamanho = $($_.Length)",
        "data    = $($_.LastWriteTime)",
        "SHA256  = $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)",
        (TextoProc (Procedencia $_.FullName))
    ) 'O agente do incidente chegou como .msi com nome de atualizacao da Adobe. Nome parecido nao prova nada por si - o que decide e a assinatura e o hash.' 'Nao executar e nao apagar. Mandar o SHA256 para a TI conferir (VirusTotal / fornecedor). Se a assinatura for de "Action1" ou estiver ausente, tratar como confirmado.'
}

# ============================================================================
# [6] OUTROS PROGRAMAS DE ACESSO REMOTO / RMM  +  higiene
#     Classe ESPERADO = ferramenta oficial da casa (presenca e' normal).
#     Classe SUSPEITO = acesso remoto que NAO faz parte do padrao IGN.
# ============================================================================
Etapa 6 $STR.e6
# se algo falhar aqui, o veredito do Action1 (Parte A) tem de sair mesmo assim
try {
    $catalogo = @(
        @{ Nome='AnyDesk';                   Rx='anydesk';                              Classe='ESPERADO' },
        @{ Nome='ScreenConnect/ConnectWise'; Rx='screenconnect|connectwise';            Classe='SUSPEITO' },
        @{ Nome='Atera';                     Rx='ateraagent|\batera\b';                 Classe='SUSPEITO' },
        @{ Nome='Splashtop';                 Rx='splashtop';                            Classe='SUSPEITO' },
        @{ Nome='NinjaRMM/NinjaOne';         Rx='ninjarmm|ninjaone';                    Classe='SUSPEITO' },
        @{ Nome='Syncro';                    Rx='syncro(agent|mps)';                    Classe='SUSPEITO' },
        @{ Nome='Level.io';                  Rx='level\.io|level-agent';                Classe='SUSPEITO' },
        @{ Nome='PDQ Connect';               Rx='pdq ?connect';                         Classe='SUSPEITO' },
        @{ Nome='Kaseya/VSA';                Rx='kaseya|agentmon';                      Classe='SUSPEITO' },
        @{ Nome='Tactical RMM';              Rx='tacticalrmm|tacticalagent';            Classe='SUSPEITO' },
        @{ Nome='RustDesk';                  Rx='rustdesk';                             Classe='SUSPEITO' },
        @{ Nome='MeshCentral/MeshAgent';     Rx='meshagent|meshcentral';                Classe='SUSPEITO' },
        @{ Nome='DWAgent';                   Rx='dwagent';                              Classe='SUSPEITO' },
        @{ Nome='UltraViewer';               Rx='ultraviewer';                          Classe='SUSPEITO' },
        @{ Nome='Ammyy Admin';               Rx='ammyy';                                Classe='SUSPEITO' },
        @{ Nome='Supremo';                   Rx='supremo';                              Classe='SUSPEITO' },
        @{ Nome='TeamViewer';                Rx='teamviewer';                           Classe='SUSPEITO' },
        @{ Nome='LogMeIn';                   Rx='logmein';                              Classe='SUSPEITO' },
        @{ Nome='Zoho Assist';               Rx='zoho ?assist|zaservice';               Classe='SUSPEITO' },
        @{ Nome='GoTo Resolve/Rescue';       Rx='goto ?(resolve|assist)|logmeinrescue'; Classe='SUSPEITO' },
        @{ Nome='Remote Utilities';          Rx='remote ?utilities|rutserv';            Classe='SUSPEITO' },
        @{ Nome='VNC (Real/Ultra/Tight)';    Rx='realvnc|ultravnc|tightvnc|vncserver';  Classe='SUSPEITO' },
        @{ Nome='ngrok / tunel';             Rx='\bngrok\b|localtonet|playit\.gg';      Classe='SUSPEITO' },
        @{ Nome='Chrome Remote Desktop';     Rx='chromoting|chrome remote desktop';     Classe='SUSPEITO' },
        @{ Nome='Parsec';                    Rx='\bparsec\b';                           Classe='SUSPEITO' },
        @{ Nome='Action1 (RMM)';             Rx='action1';                              Classe='SUSPEITO' }
    )

    # inventario coletado uma vez so
    $pastas = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA)) {
        if ($base -and (Test-Path $base)) {
            $pastas += Get-ChildItem $base -Directory | Select-Object @{n='N';e={$_.Name}}, @{n='P';e={$_.FullName}}
        }
    }
    $procs = @(Get-Process | Where-Object { $_.Path } | Select-Object Name, Path)

    foreach ($item in $catalogo) {
        $onde = @(); $bins = @(); $rodando = $false
        $instalados | Where-Object { $_.DisplayName -match $item.Rx } | ForEach-Object { $onde += "programa instalado: $($_.DisplayName) $($_.DisplayVersion)" }
        $servicos   | Where-Object { $_.Name -match $item.Rx -or $_.DisplayName -match $item.Rx -or $_.PathName -match $item.Rx } | ForEach-Object { $onde += "servico: $($_.Name) [$($_.State)]"; $bins += $_.PathName }
        $pastas     | Where-Object { $_.N -match $item.Rx } | ForEach-Object { $onde += "pasta: $($_.P)" }
        $procs      | Where-Object { $_.Name -match $item.Rx -or $_.Path -match $item.Rx } | ForEach-Object { $onde += "EM EXECUCAO AGORA: $($_.Path)"; $bins += $_.Path; $rodando = $true }

        if (-not $onde.Count) { continue }
        $onde = $onde | Select-Object -Unique
        $evid = @($onde)
        $alterado = $false
        foreach ($b in ($bins | Where-Object { $_ } | Select-Object -Unique)) {
            $pr = Procedencia $b
            $evid += (TextoProc $pr)
            if ($pr -and $pr.Status -eq 'HashMismatch') { $alterado = $true }
        }
        if ($item.Classe -eq 'ESPERADO') {
            Add-Achado "esperado-$($item.Nome)" 'B' 'INFO' "$($item.Nome) presente (ferramenta oficial da casa)" $evid 'Presenca normal na frota da IGN. Nao e achado.' 'Nada a fazer. Serve so para o inventario.'
        } else {
            $g = if ($rodando -or $alterado) { 'ALTO' } else { 'MEDIO' }
            $sig = "Acesso remoto que NAO faz parte do padrao da IGN (o padrao e AnyDesk). Pode ser legitimo - fornecedor, suporte de sistema, TI local - mas ninguem confirmou."
            if ($rodando) { $sig += " ESTA EM EXECUCAO AGORA." }
            $ac = "A TI precisa responder: QUEM pediu para instalar e QUANDO. Se ninguem souber, tratar como acesso nao autorizado. Nao desinstalar antes de preservar o log do proprio programa (e o que diz quem entrou e quando)."
            if ($alterado) {
                $g = 'CRITICO'
                $sig += " O binario foi ALTERADO depois de assinado - isso nunca e normal."
                $ac  = "Binario alterado depois de assinado nao tem explicacao benigna. Isolar a maquina da rede sem desligar e acionar a TI. " + $ac
            }
            Add-Achado "rmm-$($item.Nome)" 'B' $g "Acesso remoto fora do padrao: $($item.Nome)" $evid $sig $ac
        }
    }

    # --- servico/tarefa rodando de ProgramData ou pasta do usuario ---
    # software honesto quase nunca mora ai. Whitelist do que e' normal na frota:
    # Defender/MpDefender/NisSrv REALMENTE moram em ProgramData -> sem essa lista a
    # heuristica apitava em 18/18 maquinas (medido no 1o lote, 18/08/2026).
    $normal = 'dropbox|onedrive|slack|teams|zoom|chrome|edge|adobe|docker|steam|spotify|discord|cursor|postman|whatsapp|google|anydesk|keepass|expressvpn|nvidia|intel|lenovo|dell|edgeupdate|windows defender|mpdefendercoreservice|msmpeng|nissrv|mdcoresvc|myasus'
    $servicos | Where-Object { ($_.PathName -match 'ProgramData|\\Users\\') -and ($_.PathName -notmatch $normal) } | ForEach-Object {
        $pr = Procedencia $_.PathName
        $ruim = ProcRuim $pr
        Add-Achado 'servico-local-incomum' 'C' $(if ($ruim) {'ALTO'} else {'INFO'}) "Servico rodando de local incomum: $($_.Name)" @(
            "estado  = $($_.State)", "caminho = $($_.PathName)", (TextoProc $pr)
        ) 'Servico do Windows quase nunca mora em ProgramData ou na pasta do usuario. Programa instalado corretamente fica em Program Files. Lugar errado + sem assinatura confiavel e um dos sinais mais uteis que existem, porque nao depende de conhecer o nome da ameaca.' $(if ($ruim) {'A TI precisa identificar esse binario. Fora do lugar E sem assinatura valida: tratar como suspeito ate provar o contrario.'} else {'Assinatura confere - provavelmente legitimo. So registrar no inventario.'})
    }
    # try proprio: em Windows antigo/quebrado o modulo ScheduledTasks pode nao existir,
    # e sem este try isso derrubava a etapa 6 INTEIRA (visto no teste de 20/08/2026)
    try {
    Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' } | ForEach-Object {
        $exec = ($_.Actions | Where-Object { $_.Execute }).Execute -join ' '
        if ($exec -match 'ProgramData|\\Users\\' -and $exec -notmatch $normal) {
            $pr = Procedencia $exec
            $ruim = ProcRuim $pr
            Add-Achado 'tarefa-local-incomum' 'C' $(if ($ruim) {'ALTO'} else {'INFO'}) "Tarefa agendada de local incomum: $($_.TaskName)" @(
                "executa = $exec", "estado  = $($_.State)", (TextoProc $pr)
            ) 'Tarefa agendada e o jeito mais comum de um acesso remoto se manter vivo (reinstala/reabre sozinho). Alvo .cmd/.bat/.vbs nunca tem assinatura, entao lugar errado pesa mais.' $(if ($ruim) {'A TI precisa abrir esse arquivo e ver o que ele faz antes de qualquer limpeza. Nao apagar a tarefa antes de copiar o alvo.'} else {'Assinatura confere - provavelmente legitimo. So registrar.'})
        }
    }
    } catch { [void]$limites.Add("Nao foi possivel listar as tarefas agendadas: $($_.Exception.Message). Persistencia por tarefa agendada NAO foi verificada nesta maquina.") }

    # --- AnyDesk e' nosso, mas senha fixa deixa entrar SEM ninguem aceitar ---
    foreach ($c in @("$env:ProgramData\AnyDesk\service.conf", "$env:APPDATA\AnyDesk\service.conf")) {
        if ((Test-Path $c) -and ((Get-Content $c) -match 'pwd_hash|pwd_salt')) {
            Add-Achado 'anydesk-senha-fixa' 'C' 'MEDIO' 'AnyDesk com senha de acesso nao vigiado configurada' @("arquivo = $c") 'Com senha fixa, quem souber a senha entra na maquina SEM a pessoa aceitar nada e sem aviso na tela. E util para a TI e igualmente util para quem nao deveria.' 'Confirmar com a TI se foi ela que definiu essa senha. Se nao foi, remover a senha de acesso nao vigiado e trocar a senha da TI na frota.'
        }
    }

    # --- acesso remoto nativo do Windows (RDP) ---
    if ((Safe { (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections).fDenyTSConnections } 1) -eq 0) {
        Add-Achado 'rdp-habilitado' 'C' 'MEDIO' 'Area de Trabalho Remota (RDP) esta HABILITADA' @('HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\fDenyTSConnections = 0') 'RDP ligado permite login remoto completo com usuario e senha do Windows, sem instalar nada. Em estacao de trabalho comum nao deveria estar ligado.' 'Se ninguem usa RDP nesta maquina, desligar em Configuracoes > Sistema > Area de trabalho remota. Se usa, confirmar que nao esta exposto para a internet.'
    }
} catch {
    [void]$limites.Add("A varredura de outros acessos remotos (etapa 6) falhou nesta maquina: $($_.Exception.Message). O resultado da Parte A (Action1) continua valido.")
}

# ============================================================================
# VEREDITO
# ============================================================================
$partA  = @($F | Where-Object { $_.parte -eq 'A' })
$graves = @($F | Where-Object { $_.gravidade -in @('CRITICO','ALTO') -and $_.parte -ne 'A' })
$medios = @($F | Where-Object { $_.gravidade -eq 'MEDIO' })

if     ($partA.Count -gt 0)                        { $veredito = 'ACHADO'  }
elseif ($graves.Count -gt 0 -or $medios.Count -gt 0){ $veredito = 'REVISAR' }
else                                               { $veredito = 'LIMPO'   }

$os = Safe { Get-CimInstance Win32_OperatingSystem } $null
$cs = Safe { Get-CimInstance Win32_ComputerSystem } $null
# cada campo isolado: se um falhar, sai 'n/d' e o resto do relatorio continua inteiro
$maq = [ordered]@{
    gerado_em       = Safe { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
    gerado_em_utc   = Safe { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    computador      = Safe { $env:COMPUTERNAME }
    usuario         = Safe { $env:USERNAME }
    dominio         = Safe { $env:USERDOMAIN }
    fabricante      = Safe { $cs.Manufacturer }
    modelo          = Safe { $cs.Model }
    numero_de_serie = Safe { (Get-CimInstance Win32_BIOS).SerialNumber }
    windows         = Safe { $os.Caption }
    build           = Safe { $os.BuildNumber }
    idioma_windows  = Safe { (Get-UICulture).Name }
    idioma_relatorio= $IDIOMA
    ligado_desde    = Safe { $os.LastBootUpTime }
    powershell      = Safe { $PSVersionTable.PSVersion.ToString() }
    admin           = Safe { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    versao_script   = '2026-09-01'
}

# ============================================================================
# RELATORIO
# ============================================================================
$desktop = [Environment]::GetFolderPath("Desktop")
if (-not $desktop -or -not (Test-Path $desktop)) { $desktop = "$env:USERPROFILE\Desktop" }
# nome com USUARIO + PC + data: quando varias pessoas mandarem, da p/ saber de quem e' cada um
$limpaU  = ($env:USERNAME     -replace '[^A-Za-z0-9._-]','')
$limpaH  = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]','')
$nomeArq = "$PREFIXO_RELATORIO-$limpaU-$limpaH-$(Get-Date -Format 'yyyy-MM-dd').txt"
$arq     = Join-Path $desktop $nomeArq

$R = New-Object System.Collections.ArrayList
function W($t) { [void]$R.Add([string]$t) }

W ("=" * 78)
W " RASTREADOR DE ACESSOS REMOTOS - IG Networks"
W " Relatorio tecnico / Reporte tecnico / Technical report"
W ("=" * 78)
W ""
W "### PARA QUEM RECEBEU ESTE ARQUIVO / PARA QUIEN RECIBE ESTE ARCHIVO"
W ""
W "PT: Este arquivo e o resultado de uma verificacao de seguranca do computador."
W "    Nada foi alterado na maquina. Envie o arquivo para a TI."
W "ES: Este archivo es el resultado de una verificacion de seguridad de la"
W "    computadora. No se cambio nada. Envia el archivo a TI."
W "EN: This file is the result of a computer security check. Nothing was changed."
W "    Send the file to IT."
W ""
W ("-" * 78)
W ""
W "### INSTRUCOES PARA UMA IA (copie este arquivo inteiro no chat)"
W ""
W "Voce esta lendo o relatorio de um scanner de acesso remoto rodado em UMA"
W "estacao de trabalho Windows de uma empresa de telecom (IG Networks, LATAM)."
W "O padrao autorizado da casa e AnyDesk; qualquer outro acesso remoto exige"
W "confirmacao humana. Contexto: em 09/04/2026 um agente RMM (Action1) foi"
W "instalado em uma maquina desta frota disfarcado de atualizacao da Adobe."
W ""
W "Faca, nesta ordem:"
W "  1. Diga o VEREDITO em uma frase, para quem nao e tecnico."
W "  2. Liste os achados por gravidade (CRITICO > ALTO > MEDIO > INFO). Para"
W "     cada um: o que e, se e perigoso NESTE caso, e o que fazer."
W "  3. Diga o que este relatorio NAO consegue provar - a secao"
W "     [COBERTURA-E-LIMITES] e obrigatoria na sua resposta. NAO afirme que a"
W "     maquina esta limpa alem do que os dados sustentam."
W "  4. Termine com uma lista de acoes concretas, na ordem de prioridade."
W ""
W "Regras: nao invente achado que nao esta no arquivo; INFO nao e problema;"
W "'assinatura VALIDA' reduz muito a suspeita; 'HashMismatch' (alterado depois"
W "de assinado) nunca tem explicacao benigna; se o veredito for ACHADO, a"
W "primeira acao e sempre isolar a maquina da rede SEM desligar e SEM apagar"
W "nada, porque a maquina e prova. Os dados estruturados estao em [DADOS-JSON]"
W "no fim do arquivo."
W ""
W ("=" * 78)
W ""
W "[MAQUINA]"
foreach ($k in $maq.Keys) { W ("  {0,-16}= {1}" -f $k, $maq[$k]) }
W ""
W "[VEREDITO]"
W "  resultado = $veredito"
W "  ACHADO  = ha vestigio do agente do incidente de abril/2026 (Action1)"
W "  REVISAR = sem Action1, mas ha acesso remoto ou configuracao a conferir"
W "  LIMPO   = nenhum dos dois"
W "  contagem  = CRITICO $(@($F|Where-Object{$_.gravidade -eq 'CRITICO'}).Count) | ALTO $(@($F|Where-Object{$_.gravidade -eq 'ALTO'}).Count) | MEDIO $(@($F|Where-Object{$_.gravidade -eq 'MEDIO'}).Count) | INFO $(@($F|Where-Object{$_.gravidade -eq 'INFO'}).Count)"
W ""
W "[ACHADOS]"
if ($F.Count -eq 0) {
    W "  nenhum. Nenhum programa de acesso remoto encontrado, nem sequer os esperados."
} else {
    $ordem = @{ 'CRITICO'=1; 'ALTO'=2; 'MEDIO'=3; 'INFO'=4 }
    $i = 0
    foreach ($a in ($F | Sort-Object { $ordem[$_.gravidade] })) {
        $i++
        W ""
        W ("  --- ACHADO {0} de {1} ---" -f $i, $F.Count)
        W ("  id          : {0}" -f $a.id)
        W ("  gravidade   : {0}" -f $a.gravidade)
        W ("  parte       : {0}  (A=incidente Action1  B=acesso remoto  C=higiene)" -f $a.parte)
        W ("  titulo      : {0}" -f $a.titulo)
        W  "  evidencia   :"
        foreach ($e in $a.evidencia) { W ("                {0}" -f $e) }
        W ("  significado : {0}" -f $a.significado)
        W ("  acao        : {0}" -f $a.acao)
    }
}
W ""
W "[COBERTURA-E-LIMITES]"
W "  O que esta verificacao NAO consegue provar. Ler antes de concluir qualquer coisa:"
W "  - Ela olha 6 lugares: registro, programas instalados, log do Windows Installer,"
W "    servicos e pastas, a pasta Downloads, e processos em execucao. Malware que"
W "    nao usa nenhum desses caminhos nao aparece aqui."
W "  - Ela roda COM privilegio de administrador (o script exige, desde 01/09/2026),"
W "    entao 'ficou invisivel por falta de permissao' NAO explica um resultado vazio."
W "    Ressalva honesta: perfil de outro usuario que nunca foi carregado nesta sessao"
W "    tem o registro dele fora do alcance de qualquer varredura."
W "  - Ela olha o ESTADO AGORA. Programa que foi instalado e removido depois so"
W "    aparece se tiver deixado rastro no log do Windows Installer."
W "  - LIMPO significa 'nada encontrado nos lugares verificados', e nunca"
W "    'esta maquina nunca foi acessada'."
if ($limites.Count) { W "" ; foreach ($l in $limites) { W ("  * {0}" -f $l) } }
W ""
W "[DADOS-JSON]"
W (([pscustomobject]@{
      maquina  = $maq
      veredito = $veredito
      achados  = @($F)
      limites  = @($limites)
   }) | ConvertTo-Json -Depth 6)
W ""
W ("=" * 78)
W (" Gerado por rastreador de acessos remotos (IG Networks / TI) - versao " + $maq.versao_script + " - idioma $IDIOMA")
W ("=" * 78)

try {
    $R | Set-Content -Path $arq -Encoding UTF8 -ErrorAction Stop
} catch {
    # Desktop bloqueado/OneDrive fora do ar: nao perder o relatorio
    $arq = Join-Path $env:USERPROFILE $nomeArq
    try { $R | Set-Content -Path $arq -Encoding UTF8 -ErrorAction Stop }
    catch { $arq = Join-Path $env:TEMP $nomeArq; $R | Set-Content -Path $arq -Encoding UTF8 }
}

Contar $veredito

# ============================================================================
# TELA
# ============================================================================
Write-Host ""
if ($veredito -eq 'ACHADO') {
    Write-Host ("=" * 57) -ForegroundColor Red
    Write-Host ("  " + $STR.ach_t) -ForegroundColor Red
    Write-Host ("=" * 57) -ForegroundColor Red
    Write-Host ""
    Write-Host $STR.ach_1 -ForegroundColor Yellow
    Write-Host $STR.manda -ForegroundColor Yellow
    Write-Host ("  " + $nomeArq) -ForegroundColor White
} elseif ($veredito -eq 'REVISAR') {
    Write-Host ("=" * 57) -ForegroundColor Yellow
    Write-Host ("  " + $STR.rev_t) -ForegroundColor Yellow
    Write-Host ("=" * 57) -ForegroundColor Yellow
    Write-Host ""
    Write-Host $STR.rev_1 -ForegroundColor Gray
    Write-Host $STR.rev_2 -ForegroundColor Gray
    Write-Host $STR.rev_3 -ForegroundColor Gray
    Write-Host ""
    Write-Host $STR.manda -ForegroundColor Yellow
    Write-Host ("  " + $nomeArq) -ForegroundColor White
    Write-Host $STR.rev_4 -ForegroundColor Gray
} else {
    Write-Host ("=" * 57) -ForegroundColor Green
    Write-Host ("  " + $STR.lim_t) -ForegroundColor Green
    Write-Host ("=" * 57) -ForegroundColor Green
    Write-Host ""
    Write-Host $STR.lim_1 -ForegroundColor Gray
    if (@($F | Where-Object { $_.gravidade -eq 'INFO' }).Count) { Write-Host $STR.lim_2 -ForegroundColor DarkGray }
}
Write-Host ""
Write-Host ("{0} {1}" -f $STR.salvo, $arq) -ForegroundColor DarkGray
Write-Host $STR.ia -ForegroundColor DarkGray
Write-Host ""
