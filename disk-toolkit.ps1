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

function Get-DiskDropdownItems($includeSystem=$false) {
    $disks = if ($includeSystem) { Get-AllDisks } else { Get-NonSystemDisks }
    $items = @()
    foreach ($d in $disks) {
        $items += [PSCustomObject]@{
            Number = $d.Number
            Display = "Disk $($d.Number) - $($d.FriendlyName) - $(Format-Bytes $d.Size) ($($d.BusType))"
        }
    }
    return $items
}

function Get-VolumeDropdownItems {
    $vols = Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystem }
    $items = @()
    foreach ($v in $vols) {
        $items += [PSCustomObject]@{
            Letter = $v.DriveLetter
            Display = "$($v.DriveLetter): - $($v.FileSystemLabel) - $(Format-Bytes $v.Size) - $($v.FileSystem)"
        }
    }
    return $items
}

# ============= Cataloog de acoes =============
# Estrutura: nome interno, nome amigavel, categoria, descricao, funcao a chamar

$script:actions = @(
    # === INFORMACAO ===
    @{Id='smart'; Name='S.M.A.R.T. (Saude do disco)'; Cat='INFORMACAO'; Desc='Le o status auto-reportado pelo proprio drive. Mostra saude geral (OK/Warning/Critical), horas de uso, temperatura, setores realocados e contagem de erros. Util pra detectar disco em pre-falha antes que dê problema serio.'},
    @{Id='info'; Name='Informacoes detalhadas'; Cat='INFORMACAO'; Desc='Mostra tudo que da pra saber sobre um disco: modelo, serial, firmware, tipo (HDD/SSD/NVMe), tabela (GPT/MBR), barramento (SATA/USB/NVMe), tamanho total, particoes existentes e seus filesystems.'},

    # === PARTICAO ===
    @{Id='wipe'; Name='Apagar e formatar (Wipe & Format)'; Cat='PARTICAO'; Desc='ATENCAO: Operacao destrutiva. Apaga TUDO do disco (partições, dados, recovery, OEM), cria nova tabela GPT, cria uma unica particao ocupando o disco inteiro e formata em NTFS com a label escolhida. Use pra preparar HDD secundario novo ou limpar HDD vindo de outro PC.'},
    @{Id='label'; Name='Trocar label do volume'; Cat='PARTICAO'; Desc='Renomeia o volume (ex: "HDD" para "Backup") sem precisar formatar nem perder nenhum dado. So muda o nome que aparece no Explorer.'},
    @{Id='letter'; Name='Trocar letra de drive'; Cat='PARTICAO'; Desc='Reatribui a letra do drive (ex: E: vira D:) sem mexer nos dados. Util quando o Windows escolhe uma letra esquisita ou voce quer organizar.'},
    @{Id='resize'; Name='Redimensionar particao'; Cat='PARTICAO'; Desc='Diminui ou aumenta o tamanho de uma particao existente, sem perder dados. Pra diminuir, precisa ter espaco livre no volume. Pra aumentar, precisa ter espaco nao alocado adjacente no disco.'},
    @{Id='format'; Name='Formatar com escolha de FS'; Cat='PARTICAO'; Desc='ATENCAO: Apaga todos os dados da particao escolhida. Diferente do Wipe&Format, este só reformata uma particao especifica (não mexe nas outras). Permite escolher entre NTFS, exFAT, FAT32 ou ReFS.'},

    # === MANUTENCAO ===
    @{Id='chkdsk'; Name='Checagem de integridade (CHKDSK)'; Cat='MANUTENCAO'; Desc='Roda CHKDSK pra verificar erros no sistema de arquivos da partição. Com o modo "Corrigir", tenta consertar erros encontrados e marcar setores defeituosos como inacessiveis. Recomenda agendar se o disco estiver em uso.'},
    @{Id='defrag'; Name='Desfragmentar / Otimizar'; Cat='MANUTENCAO'; Desc='Detecta automaticamente se o disco e HDD ou SSD. Em HDD: desfragmenta arquivos pra melhorar velocidade de leitura. Em SSD: roda TRIM (retorna celulas nao usadas pra controlador, mantem performance).'},
    @{Id='wipefree'; Name='Limpar espaco livre (impede recuperacao)'; Cat='MANUTENCAO'; Desc='Sobrescreve com zeros toda a area marcada como livre no disco. Arquivos que voce apagou antes mas que ainda existiam no disco (recuperaveis com software) deixam de existir. Util antes de doar/vender PC. Pode demorar bastante (1+ hora em discos grandes).'},

    # === BACKUP ===
    @{Id='backupuser'; Name='Backup arquivos de usuario'; Cat='BACKUP'; Desc='Copia pastas pessoais dos usuarios do Windows (Desktop, Documentos, Imagens, etc.) pra um disco destino. Voce escolhe quais perfis e quais pastas. Usa robocopy multi-thread (rapido + retoma se cair).'},
    @{Id='clonedados'; Name='Clonar disco de dados'; Cat='BACKUP'; Desc='Espelha o conteudo de um disco/volume em outro. NAO clona o disco do sistema (Windows nao deixa enquanto rodando). So pra discos de dados (D:, E:, etc.).'},
    @{Id='vhdx'; Name='Imagem VHDX (snapshot do C:)'; Cat='BACKUP'; Desc='Cria um arquivo .vhdx no disco destino contendo um snapshot do C: tirado a quente via VSS (sem desligar). Util como backup antes de operacoes arriscadas, ou pra recuperar dados se o Windows corromper depois. Use Disk2VHD da Sysinternals.'},

    # === USUARIOS ===
    @{Id='users'; Name='Listar e apagar perfis de usuario'; Cat='USUARIOS'; Desc='Lista todos os perfis locais do Windows com nome, tamanho ocupado em disco e ultimo login. Permite apagar perfis antigos (remove pasta C:\Users\xyz + conta + entrada no registro) pra liberar espaco. Bloqueia o perfil em uso (voce nao consegue apagar quem ta logado).'},
    @{Id='createuser'; Name='Criar novo usuario local'; Cat='USUARIOS'; Desc='Cria uma conta LOCAL do Windows (sem vinculo com conta Microsoft) com nome de usuario e senha definidos por voce. Opcionalmente da privilegio de Administrador. Util pra criar conta tecnica em PCs em manutencao ou conta nova pra um colaborador.'}
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
            Add-Label 10 70 200 22 "Label do novo volume:" $true
            $script:ctx.label = Add-Textbox 10 95 200 "HDD"
            Add-Label 10 130 460 80 "ATENCAO: Esta operacao apaga TUDO no disco selecionado.`nNao ha como desfazer."
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
            Add-Label 10 10 200 22 "Selecione o volume:" $true
            $script:ctx.vol = Add-Combo 10 35 460 (Get-VolumeDropdownItems)
            $script:ctx.fix = Add-Checkbox 10 70 460 "Corrigir erros encontrados (chkdsk /f)" $false
            $script:ctx.scan = Add-Checkbox 10 95 460 "Verificar e marcar setores defeituosos (chkdsk /r - LENTO)" $false
            Add-Label 10 130 460 60 "Em uma partição em uso, sera agendado pra rodar no proximo boot."
            $script:ctx.output = Add-Multiline 10 195 460 75
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
    }
}

# ============= Executores =============

function Execute-Action($id) {
    Set-Status "Executando..." ([System.Drawing.Color]::DarkOrange)

    try {
        switch ($id) {
            'smart'      { Exec-Smart }
            'info'       { Exec-Info }
            'wipe'       { Exec-Wipe }
            'label'      { Exec-Label }
            'letter'     { Exec-Letter }
            'resize'     { Exec-Resize }
            'format'     { Exec-Format }
            'chkdsk'     { Exec-Chkdsk }
            'defrag'     { Exec-Defrag }
            'wipefree'   { Exec-WipeFree }
            'backupuser' { Exec-BackupUser }
            'clonedados' { Exec-CloneData }
            'vhdx'       { Exec-Vhdx }
            'users'      { Exec-DeleteUser }
            'createuser' { Exec-CreateUser }
        }
    } catch {
        Set-Status "Erro: $($_.Exception.Message)" ([System.Drawing.Color]::DarkRed)
        Show-Msg "Erro durante a operacao:`n`n$($_.Exception.Message)" "Erro" "Error"
    }
}

# --- INFO ---
function Exec-Smart {
    $diskNum = $script:ctx.disk.SelectedItem.Number
    $disk = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq $diskNum }
    $health = $disk.HealthStatus
    $reliab = Get-StorageReliabilityCounter -PhysicalDisk $disk -ErrorAction SilentlyContinue

    $out = "=== S.M.A.R.T. - Disk $diskNum ===`n`n"
    $out += "Modelo:           $($disk.FriendlyName)`n"
    $out += "Serial:           $($disk.SerialNumber)`n"
    $out += "Saude:            $health (OperationalStatus: $($disk.OperationalStatus))`n"
    if ($reliab) {
        $out += "Horas ligado:     $($reliab.PowerOnHours) h`n"
        $out += "Temperatura:      $($reliab.Temperature) C  (Max ja registrado: $($reliab.TemperatureMax) C)`n"
        $out += "Leituras:         $($reliab.ReadErrorsTotal) erros / $($reliab.ReadErrorsUncorrected) nao corrigiveis`n"
        $out += "Escritas:         $($reliab.WriteErrorsTotal) erros / $($reliab.WriteErrorsUncorrected) nao corrigiveis`n"
        $out += "Setores realocados: $($reliab.ReadErrorsCorrected)`n"
        $out += "Wear (uso desgaste): $($reliab.Wear) %`n"
    } else {
        $out += "(Driver do disco nao expoe contadores de confiabilidade - normal em USB)`n"
    }
    $script:ctx.output.Text = $out
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
    $script:ctx.output.Text = $out
    Set-Status "OK" ([System.Drawing.Color]::DarkGreen)
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

    if (-not (Confirm-Action "Apagar TUDO no Disk $($sel.Number) e formatar como NTFS '$label'?`n`nIrreversivel.")) { return }

    Clear-Disk -Number $sel.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    $d = Get-Disk -Number $sel.Number
    if ($d.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $sel.Number -PartitionStyle GPT -ErrorAction Stop }
    $part = New-Partition -DiskNumber $sel.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    Format-Volume -DriveLetter $part.DriveLetter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null

    Show-Msg "Disk $($sel.Number) pronto na letra $($part.DriveLetter): como '$label'" "Sucesso"
    Set-Status "Disk $($sel.Number) -> $($part.DriveLetter): NTFS '$label'" ([System.Drawing.Color]::DarkGreen)
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
function Exec-Chkdsk {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $cdArgs = @("$($sel.Letter):")
    if ($script:ctx.fix.Checked) { $cdArgs += "/f" }
    if ($script:ctx.scan.Checked) { $cdArgs += "/r" }
    $output = chkdsk @cdArgs 2>&1 | Out-String
    $script:ctx.output.Text = $output
    Set-Status "CHKDSK $($sel.Letter): concluido (ver saida acima)" ([System.Drawing.Color]::DarkGreen)
}

function Exec-Defrag {
    $sel = $script:ctx.vol.SelectedItem; if (-not $sel) { return }
    $output = Optimize-Volume -DriveLetter $sel.Letter -Verbose -ErrorAction Stop 4>&1 | Out-String
    $script:ctx.output.Text = $output
    Set-Status "Otimizacao concluida em $($sel.Letter):" ([System.Drawing.Color]::DarkGreen)
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

    if ($status -eq "EM USO") { Show-Msg "Perfil em uso, nao pode ser removido." 'Aviso' 'Warning'; return }
    if ($name -in @('Administrator','DefaultAccount','Guest','WDAGUtilityAccount')) {
        Show-Msg "Perfil de sistema, nao remova." 'Aviso' 'Warning'; return
    }

    if (-not (Confirm-Action "Apagar perfil '$name' completamente?`n`nIsso remove:`n - Pasta $path`n - Conta de usuario local`n - Entradas no registro`n`nIrreversivel.")) { return }

    # 1. Remover via Win32_UserProfile (limpa registro tambem)
    Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -eq $path } | Remove-CimInstance -ErrorAction Stop

    # 2. Remover a conta de usuario (se existir)
    try { Remove-LocalUser -Name $name -ErrorAction Stop } catch {}

    # 3. Limpar pasta residual se nao foi removida
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
    }

    Show-Msg "Perfil '$name' apagado." "Sucesso"
    Set-Status "Perfil $name removido" ([System.Drawing.Color]::DarkGreen)
    Build-Panel 'users'  # refresh lista
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
