# Formatei o PC e Agora o Que Fazer?

Script PowerShell que automatiza a configuracao de um PC Windows apos uma formatacao. Remove bloatware, instala programas, personaliza o sistema e desativa o que nao precisa.

**Compativel com Windows 10 e 11.**

---

## Como Usar

1. Abrir o **PowerShell como Administrador**
2. Colar e executar o comando:

### Setup Completo (8 etapas)
```powershell
Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4") }; irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/setup.ps1 | iex
```

### Setup Light (5 etapas — so Chrome + limpezas)
```powershell
Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4") }; irm https://raw.githubusercontent.com/GCintra00/formatei-pc/master/setup-light.ps1 | iex
```

> O prefixo configura o DNS do Google (8.8.8.8) **antes** de baixar o script, garantindo que o download funcione mesmo em PCs recem-formatados com DNS lento.

> O script exige permissoes de administrador. Se nao estiver rodando como admin, ele avisa e encerra.

---

## O Que o Script Faz

O script executa **8 etapas** na seguinte ordem:

### [1] Remover Bloatware

Remove aplicativos pre-instalados do Windows que nao sao necessarios:

| Categoria | Programas removidos |
|-----------|-------------------|
| Antivirus | McAfee (todos os componentes) |
| Microsoft | OneDrive, Teams, Solitaire, Office Hub, Mail, Clipchamp, Todos |
| Xbox | Xbox App, Game Overlay, Gaming Overlay, Speech to Text, Identity Provider, TCUI |
| Redes sociais | Facebook, Instagram, TikTok, LinkedIn, Skype |
| Entretenimento | Spotify, Candy Crush, Disney+ |
| Noticias | Bing News, Bing Weather, Get Help, Get Started |

A remocao e feita via `Remove-AppxPackage`, `Remove-AppxProvisionedPackage`, `WMI` (McAfee) e `winget uninstall` (OneDrive e Teams). O OneDrive e Teams tambem tem seus processos encerrados antes da remocao.

### [2] Instalar Programas (via Winget)

Instala automaticamente (modo silencioso):

| Programa | Winget ID |
|----------|-----------|
| Google Chrome | `Google.Chrome` |
| Discord | `Discord.Discord` |
| Steam | `Valve.Steam` |
| Epic Games Launcher | `EpicGames.EpicGamesLauncher` |
| Opera GX | `Opera.OperaGX` |
| Bambu Studio | `Bambulab.Bambustudio` |
| Logitech G Hub | `Logitech.GHUB` |
| Lightshot | `Skillbrains.Lightshot` |
| Calibre | `calibre.calibre` |
| HakuNeko | `HakuNeko.HakuNeko` |
| KCC (Kindle Comic Converter) | `ciromattia.KCC` |
| Kindle Previewer | `Amazon.KindlePreviewer` |

**AnyDesk** e baixado do GitHub Release e requer um clique manual para instalar como servico.

### [3] Instalar Programas (via GitHub Releases)

Programas que nao estao disponiveis no Winget ou que davam erro sao baixados da release `v1.0` do repositorio:

| Programa | Observacao |
|----------|-----------|
| **WinRAR 7.11 BR** | Instalacao silenciosa (`/S`) |
| **STL Thumb** | Thumbnails de arquivos STL no Explorer |
| **uTorrent Web** | Requer cliques manuais: `Next > Agree > Skip All > Finish` |

### [4] Baixar Arquivos Extras

Cria a pasta `Downloads Setup` na Area de Trabalho e baixa:

- `K585 DITI half hand.zip` — Software do teclado mecanico K585
- `Kurama Software e reset K552RGB-BRS.rar` — Software e reset do teclado K552
- `wallpaper opera.jpg` — Wallpaper para o Opera GX
- `Abrir_NVIDIA_Drivers.url` — Atalho para baixar drivers NVIDIA
- `WinKeygen.rar` — Ativador do Windows

Tambem cria a subpasta `Kindle` com atalhos para os 4 apps de leitura (Calibre, HakuNeko, KCC, Kindle Previewer).

### [5] Configurar Wallpaper e Sons

- **Wallpaper**: Baixa e aplica automaticamente o wallpaper do Windows via API `SystemParametersInfo`
- **Sons USB personalizados**:
  - Dispositivo conectado: `Yamete Kudasai.wav`
  - Dispositivo desconectado: `Kyaa.wav`

Os sons sao salvos em `%USERPROFILE%\Sounds` e configurados via registro do Windows.

### [6] Desativar Notificacoes

Desativa **todas** as notificacoes do Windows via registro:

- Toasts (notificacoes popup)
- Sons de notificacao
- Central de Notificacoes
- Notificacoes na tela de bloqueio
- Sugestoes e dicas do Windows
- Notificacoes via politica de grupo (mais agressivo)
- Windows Tips e Consumer Features

### [7] Limpar Barra de Tarefas e Menu Iniciar

**Remove da barra de tarefas:**
- Cortana
- Widgets
- Chat/Teams
- Botao de Task View
- Campo de busca
- Noticias e Interesses (Win 10)

**Limpa o Menu Iniciar** removendo todos os tiles/pins.

**Tenta fixar na barra** (na ordem):
1. Opera GX
2. Google Chrome
3. Explorador de Arquivos

> **Limitacao**: No Windows 11, fixar programas na barra via script nao funciona de forma confiavel (restricao da Microsoft). Fazer manualmente.

### [8] Remover Programas do Inicio Automatico

Remove **todos** os itens de auto-inicio, mantendo apenas:

| Programa | Motivo |
|----------|--------|
| AnyDesk (`--control`) | Acesso remoto em segundo plano |
| Lightshot | Screenshots rapidos |
| SecurityHealth | Windows Defender |
| RtkAudUService | Driver de audio Realtek |

A limpeza e feita em multiplas camadas:
- Registro `HKCU\...\Run` e `HKLM\...\Run`
- Pastas Startup (usuario e comum)
- `StartupApproved` (desativa no Gerenciador de Tarefas)
- Tarefas agendadas de logon
- Configs especificas: Discord (`settings.json`), Steam, Slack, Epic Games, Logitech G Hub

---

## Configuracao Inicial

Antes de rodar o script, o DNS e automaticamente configurado para o **Google DNS** (`8.8.8.8` / `8.8.4.4`) em todos os adaptadores de rede ativos.

---

## Resumo Final

Ao terminar, o script exibe um resumo com:
- Lista de todos os programas e seus status (Instalado / Ja instalado / ERRO)
- Contagem de erros, se houver

---

## Estrutura do Release (v1.0)

Arquivos hospedados na release do GitHub:

```
AnyDesk.exe
STL-Thumb-Windows_0.5.0.exe
utweb_installer.exe
winrar-x64-711br.exe
WinKeygen.rar
K585.DITI.half.hand.zip
Kurama.Software.e.reset.K552RGB-BRS.rar
wallpaper.opera.jpg
wallpaper.windows.jpg
Kyaa.wav
Yamete.Kudasai.wav
Abrir_NVIDIA_Drivers.url
```

---

## Notas Tecnicas

- **WinRAR** via release porque o Winget dava erro na instalacao
- **AnyDesk** precisa de clique manual para instalar como servico
- **uTorrent Web** precisa de cliques manuais (Next > Agree > Skip All > Finish)
- **Explorer nao reinicia** no final do script (evita abrir janela indesejada). As mudancas da barra de tarefas aplicam no proximo reinicio
- **Fusion 360** foi removido do script (atualizacoes frequentes, licenca pessoal precisa ser baixada na hora)
