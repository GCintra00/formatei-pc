#Requires -RunAsAdministrator
# prepare-storage.ps1
# GUI WinForms para preparar HDD/SSD secundario como storage interno (NTFS, GPT, 1 particao)
# Bloqueia disco do sistema. Confirmacao dupla antes do wipe.
# Funciona via arquivo (.\prepare-storage.ps1) ou pipe (irm ... | iex)

# Runtime admin check (alem do #Requires, que so funciona via arquivo)
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "ERRO: Este script precisa rodar como Administrador." -ForegroundColor Red
    Write-Host "Abra o PowerShell como administrador e tente novamente." -ForegroundColor Yellow
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =============== Estado ===============
$script:disksData = @()   # array de hashtables com info dos discos disponiveis

# =============== Funcoes ===============

function Get-SystemDiskNumber {
    # Identifica o numero do disco que contem a particao do sistema (C:)
    try {
        $sysDrive = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name SystemRoot -ErrorAction Stop).SystemRoot.Substring(0,1)
        $partition = Get-Partition -DriveLetter $sysDrive -ErrorAction Stop
        return $partition.DiskNumber
    } catch {
        # Fallback: pega o disco de boot via Get-Disk
        $bootDisk = Get-Disk | Where-Object { $_.IsBoot -or $_.IsSystem } | Select-Object -First 1
        if ($bootDisk) { return $bootDisk.Number }
        return -1
    }
}

function Refresh-DiskList {
    $script:disksData = @()
    $listView.Items.Clear()

    $sysDiskNum = Get-SystemDiskNumber
    $disks = Get-Disk | Where-Object { $_.Number -ne $sysDiskNum -and $_.OperationalStatus -eq 'Online' }

    if (-not $disks) {
        $item = New-Object System.Windows.Forms.ListViewItem("(nenhum disco secundario detectado)")
        $item.SubItems.Add("") | Out-Null
        $item.SubItems.Add("") | Out-Null
        $item.SubItems.Add("") | Out-Null
        $item.ForeColor = [System.Drawing.Color]::Gray
        $listView.Items.Add($item) | Out-Null
        $btnWipe.Enabled = $false
        return
    }

    foreach ($d in $disks) {
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        $partCount = (Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Measure-Object).Count
        $model = if ($d.FriendlyName) { $d.FriendlyName } else { "(desconhecido)" }
        $busType = $d.BusType

        $item = New-Object System.Windows.Forms.ListViewItem("Disk $($d.Number)")
        $item.SubItems.Add($model) | Out-Null
        $item.SubItems.Add("$sizeGB GB") | Out-Null
        $item.SubItems.Add("$partCount part. ($busType)") | Out-Null
        $item.Tag = $d.Number
        $listView.Items.Add($item) | Out-Null

        $script:disksData += @{
            Number = $d.Number
            Model = $model
            SizeGB = $sizeGB
            BusType = $busType
        }
    }

    $btnWipe.Enabled = $true
}

function Invoke-WipeAndFormat {
    if ($listView.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione um disco da lista primeiro.", "Aviso", 'OK', 'Warning') | Out-Null
        return
    }

    $diskNum = $listView.SelectedItems[0].Tag
    $disk = $script:disksData | Where-Object { $_.Number -eq $diskNum } | Select-Object -First 1
    $label = $txtLabel.Text.Trim()

    if (-not $label) { $label = "HDD" }
    if ($label.Length -gt 32) {
        [System.Windows.Forms.MessageBox]::Show("Label NTFS aceita ate 32 caracteres.", "Aviso", 'OK', 'Warning') | Out-Null
        return
    }

    # Sanity check final: garantir que nao eh disco do sistema
    $sysDiskNum = Get-SystemDiskNumber
    if ($diskNum -eq $sysDiskNum) {
        [System.Windows.Forms.MessageBox]::Show("BLOQUEADO: Disk $diskNum eh o disco do sistema. Operacao abortada.", "Erro Critico", 'OK', 'Error') | Out-Null
        return
    }

    # Confirmacao dupla
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "ATENCAO - operacao destrutiva:`n`n" +
        "  Disk $($disk.Number)`n" +
        "  $($disk.Model)`n" +
        "  $($disk.SizeGB) GB ($($disk.BusType))`n`n" +
        "Sera APAGADO COMPLETAMENTE e formatado como NTFS com label '$label'.`n`n" +
        "TODOS os dados serao perdidos. Continuar?",
        "Confirmar wipe",
        'YesNo', 'Warning')
    if ($confirm -ne 'Yes') { return }

    $statusLabel.Text = "Trabalhando... aguarde"
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # 1. Limpar disco (remove particoes e dados)
        Clear-Disk -Number $diskNum -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop

        # 2. Inicializar como GPT (se necessario)
        $d = Get-Disk -Number $diskNum
        if ($d.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop
        }

        # 3. Criar particao ocupando tudo + letra automatica
        $part = New-Partition -DiskNumber $diskNum -UseMaximumSize -AssignDriveLetter -ErrorAction Stop

        # 4. Formatar NTFS quick
        Format-Volume -DriveLetter $part.DriveLetter -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop | Out-Null

        $statusLabel.Text = "OK - Disk $diskNum formatado como '$label' na letra $($part.DriveLetter):"
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen

        [System.Windows.Forms.MessageBox]::Show(
            "Disco preparado com sucesso!`n`n" +
            "  Letra: $($part.DriveLetter):`n" +
            "  Label: $label`n" +
            "  Sistema: NTFS`n" +
            "  Tamanho: $($disk.SizeGB) GB",
            "Pronto", 'OK', 'Information') | Out-Null

        Refresh-DiskList
    } catch {
        $statusLabel.Text = "Erro: $($_.Exception.Message)"
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
        [System.Windows.Forms.MessageBox]::Show("Erro durante operacao:`n`n$($_.Exception.Message)", "Erro", 'OK', 'Error') | Out-Null
    }
}

# =============== UI ===============

$form = New-Object System.Windows.Forms.Form
$form.Text = "Preparar HDD Storage"
$form.Size = New-Object System.Drawing.Size(560, 380)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$header = New-Object System.Windows.Forms.Label
$header.Text = "Discos disponiveis (disco do sistema oculto):"
$header.Location = New-Object System.Drawing.Point(15, 12)
$header.Size = New-Object System.Drawing.Size(500, 20)
$form.Controls.Add($header)

$listView = New-Object System.Windows.Forms.ListView
$listView.Location = New-Object System.Drawing.Point(15, 35)
$listView.Size = New-Object System.Drawing.Size(515, 180)
$listView.View = "Details"
$listView.FullRowSelect = $true
$listView.MultiSelect = $false
$listView.GridLines = $true
$listView.Columns.Add("Disco", 80) | Out-Null
$listView.Columns.Add("Modelo", 220) | Out-Null
$listView.Columns.Add("Tamanho", 90) | Out-Null
$listView.Columns.Add("Particoes", 110) | Out-Null
$form.Controls.Add($listView)

$lblLabel = New-Object System.Windows.Forms.Label
$lblLabel.Text = "Label do volume:"
$lblLabel.Location = New-Object System.Drawing.Point(15, 230)
$lblLabel.Size = New-Object System.Drawing.Size(110, 22)
$form.Controls.Add($lblLabel)

$txtLabel = New-Object System.Windows.Forms.TextBox
$txtLabel.Location = New-Object System.Drawing.Point(130, 227)
$txtLabel.Size = New-Object System.Drawing.Size(200, 22)
$txtLabel.Text = "HDD"
$txtLabel.MaxLength = 32
$form.Controls.Add($txtLabel)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Atualizar lista"
$btnRefresh.Location = New-Object System.Drawing.Point(15, 270)
$btnRefresh.Size = New-Object System.Drawing.Size(140, 32)
$btnRefresh.Add_Click({ Refresh-DiskList })
$form.Controls.Add($btnRefresh)

$btnWipe = New-Object System.Windows.Forms.Button
$btnWipe.Text = "WIPE && FORMAT"
$btnWipe.Location = New-Object System.Drawing.Point(370, 270)
$btnWipe.Size = New-Object System.Drawing.Size(160, 32)
$btnWipe.BackColor = [System.Drawing.Color]::FromArgb(220, 60, 60)
$btnWipe.ForeColor = [System.Drawing.Color]::White
$btnWipe.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnWipe.Add_Click({ Invoke-WipeAndFormat })
$form.Controls.Add($btnWipe)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ""
$statusLabel.Location = New-Object System.Drawing.Point(15, 315)
$statusLabel.Size = New-Object System.Drawing.Size(515, 22)
$statusLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($statusLabel)

# Inicializa lista
Refresh-DiskList

[void]$form.ShowDialog()
