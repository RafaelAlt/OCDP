# OCDP — OpenCode Desktop Portable

> [Read in English](README.md)

Launcher portátil do **OpenCode Desktop** para Windows: executa o app com um
ambiente isolado cujos dados ficam dentro da própria pasta portátil (sem
junctions, sem escrever no perfil da máquina), mantém o app atualizado a partir
do feed oficial com verificação de integridade (sha512) e o inicia em modo
portátil.

> Requisitos: Windows 10+ (x64 ou arm64), PowerShell 5.1. O `curl.exe` (Win10 1803+)
> é usado quando disponível; há fallback automático sem ele.

## Uso

- **Duplo clique em `launcher\OCDP.cmd`** — faz tudo (isola → update → launch).
- Flags (via `launcher\OCDP.cmd -Flag`):

| Flag | Efeito |
|---|---|
| `-NoUpdate` | Não verifica/baixa atualização. Falha se não houver app instalado. |
| `-Force` | Reinstala mesmo se estiver atualizado. Incompatível com `-NoUpdate`. |
| `-Lang` | Força o idioma da interface (`en`, `pt-BR`). |
| `-Help` | Mostra a ajuda e sai. |

- Variável de ambiente `OCDP_LANG` faz o mesmo que `-Lang` (o parâmetro vence).
- Idioma padrão: o do Windows, com fallback para inglês.

## Instalar a partir de um clone (GitHub)

1. Clone ou baixe o repositório — ele contém apenas o `launcher\`, o README e
   as licenças (o OpenCode **não** vai junto).
2. Duplo clique em `launcher\OCDP.cmd`.
3. No primeiro uso, o launcher baixa o OpenCode do feed oficial (~226 MB,
   validado por sha512), cria `app-64\`, `home\` e `projects\` ao lado e abre
   o app. Vindo do v2 (layout antigo `data\`)? A primeira execução move
   `data\*` para `home\` automaticamente e remove as junctions antigas — veja
   o `ocdp.log`.
4. Configurações, sessões e credenciais ficam em `home\` — apagar `app-64\`
   é seguro (o launcher reinstala); apagar `home\` apaga seus dados de verdade.

## Estrutura

```
OCDP\
├── README.md           este arquivo (inglês; capa do GitHub)
├── README.pt-BR.md     mesma documentação em português
├── LICENSE             licença MIT do OCDP
├── AGENTS.md           regras universais para agentes (o launcher as implanta no slot global portátil a cada run)
├── .gitignore          o que não vai para o GitHub (app-64, home, logs)
├── app-64\             o aplicativo (nome histórico; contém o build x64 ou arm64)
├── projects\           casa padrão dos seus projetos (viaja com a pasta)
├── home\               o ambiente isolado do app: TODOS os dados do OpenCode vivem aqui
└── launcher\           tudo que é específico do OCDP (vai pro GitHub)
    ├── OCDP.cmd        ponto de entrada (define OPENCODE_DISABLE_AUTOUPDATE)
    ├── ocdp.ps1        o launcher (código/comentários em inglês, UI localizada)
    ├── ocdp.log        log de execuções (rotaciona para ocdp.log.old > 512 KB)
    ├── root.marker     raiz portátil anterior (estado do remapeamento, reescrito a cada run)
    ├── 7za.exe/.dll    extrator do instalador NSIS
    ├── sqlite3.exe     ferramenta do reparo de estado salvo (domínio público)
    ├── LICENSE-7za.txt licença do 7-Zip (LGPL)
    ├── sweep-files.ps1 varredura de arquivos opencode/ocdp (somente leitura)
    └── sweep-system.ps1 varredura de registro/sistema (somente leitura)
```

### O que tem em `home\`

O app roda com ambiente isolado: `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` e os
slots `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` apontam para `home\`.
Esses são os caminhos reais usados pelo app — nada aqui é junction:

| Pasta | Slot | Conteúdo | Dado de usuário? |
|---|---|---|---|
| `home\.local\share\opencode` | `XDG_DATA_HOME` | Banco `opencode.db` (sessões, mensagens, credenciais/API keys), logs, snapshots | 🔑 Sim |
| `home\.config\opencode` | `XDG_CONFIG_HOME` | `opencode.json` (settings), o `AGENTS.md` gerenciado | ⚠️ Sim |
| `home\.local\state\opencode` | `USERPROFILE` | Estado da execução atual (PID, porta, senha local) | ⚠️ Volátil |
| `home\AppData\Roaming\ai.opencode.desktop` | `APPDATA` | Perfil Electron: rascunhos (drafts), Local Storage, cookies, logs, caches, `cli\opencode-cli.exe` | ⚠️ Parcial |
| `home\.cache\opencode` | `XDG_CACHE_HOME` | Cache (ex.: `rg.exe`) — apagável | ❌ Não |
| `home\AppData\Local` | `LOCALAPPDATA` | Slot reserva (escritas avulsas); geralmente vazio | ❌ Não |

As pastas reais da máquina (`C:\Users\<você>\...`) nunca são tocadas; o `HOME`
fica de propósito no perfil real para que git/ssh dentro das sessões de agente
continuem achando `.gitconfig`/`.ssh`.

## Como funciona (resumo)

1. **Trava de instância** (mutex por raiz portátil): um segundo `OCDP.cmd`
   simultâneo falha rápido, sem competir no download/swap.
2. **Encerra qualquer processo `*opencode*`** (app, sidecar "opencode-cli",
   TUI, instalador) — evitam-se arquivos travados na migração/swap — e
   esvazia o raspeiro de sessão (`%TEMP%\opencode`).
3. **Ambiente isolado**: em vez de reescrever as pastas da máquina, o launcher
   inicia o app com `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` e
   `XDG_DATA_HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME` apontando para `home\`.
   O app e tudo que ele gera (sidecar, agentes, ferramentas) resolve seus
   caminhos ali. Na primeira execução após subir do v2, o layout antigo
   `data\` é movido para `home\` e as junctions antigas são removidas (só o
   link) — o perfil da máquina nunca é escrito.
4. **Projetos + sessões salvas**: cria a pasta padrão `projects\` e, com o app
   parado, repara as localizações de sessão salvas no desktop
   (`home\AppData\Roaming\ai.opencode.desktop\drafts.sqlite`) e no banco de
   sessões (`home\.local\share\opencode\opencode.db`). Se a pasta portátil mudou de
   caminho/máquina (`launcher\root.marker` guarda a raiz anterior), os caminhos
   salvos sob ela são remapeados. Projetos movidos para `projects\` acordam
   automaticamente: um caminho salvo cujo nome de pasta existe sob
   `projects\` é reapontado para lá (abas do desktop, lista de projetos e
   sessões). O que continuar inexistente é removido, um último projeto
   inválido cai para `projects\`, e entradas de projetos podadas por
   execuções anteriores são restauradas a partir do banco de sessões. É isso
   que impede o app de abrir travado numa tela de "sessão não encontrada" em
   outra máquina. O reparo nunca bloqueia o boot: qualquer falha vai para o
   log (`ocdp.log`) e é retentada na próxima execução.
5. **Updater nativo desabilitado de propósito** (3 camadas):
   `OPENCODE_DISABLE_AUTOUPDATE=1` (env), `opencode.json` (`update: disable` /
   `autoupdate: false`) e remoção de `resources\app-update.yml`. Atualizações
   vêm SOMENTE deste script (feed oficial + sha512).
6. **Atualização**: lê o `latest.yml` oficial (com retry e TLS 1.2), compara
   versões, baixa o instalador (curl com fallback), **valida sha512 + tamanho**,
   extrai com 7za para `app-64.new`, remove `app-update.yml`, faz o swap
   (`app-64` → `app-64.old` → remoção com retries). Pastas travadas geram erro
   claro, nunca corrupção silenciosa; se a aplicação da nova versão falhar no
   meio do swap, a instalação anterior é restaurada automaticamente (rollback).
7. **Lançamento** de `app-64\OpenCode.exe` com o ambiente isolado — a janela
   do launcher **fecha sozinha** (o app roda destacado do console); em erro,
   ela permanece aberta com a mensagem legível.

## Solução de problemas

| Sintoma | Explicação / ação |
|---|---|
| "encerrando processos relacionados..." ao abrir | Normal (por design): evita conflito de arquivos. |
| "outra instância do OCDP já está em execução" | Espere um instante e rode de novo. |
| "pasta antiga/preparação ainda travada" | Só aparece se algo segurar mesmo após tentativas automáticas — feche os processos (`OpenCode`, `opencode-cli`) e tente de novo. |
| "não foi possível ler o feed de atualização" | Veja `launcher\ocdp.log` — a causa real (DNS/TLS/proxy) fica registrada. |
| "não foi possível encerrar: ..." | Feche manualmente pelo Gerenciador de Tarefas e rode de novo. |
| "reparando localizações de sessão salvas: ignorado (...)" | O reparo não pôde rodar (ex.: `sqlite3.exe` ausente/bloqueado). Fica no `ocdp.log`; a próxima execução retenta. Nunca bloqueia o boot. |
| Onde ver problemas | `launcher\ocdp.log` (launcher) e `home\.local\share\opencode\log\opencode.log` (app). |

## Notas importantes

- **Nunca apague o conteúdo de `home\`**: é o dado real do app. Sob isolamento
  o app não lê as pastas de perfil da máquina, então uma segunda instalação
  (não portátil) do OpenCode, se existir, é totalmente separada.
- **Mover a pasta OCDP inteira é seguro**: o `home\` viaja junto; localizações
  salvas são remapeadas via `launcher\root.marker`, e o estado do serviço
  (`home\.local\state\opencode`, PID/porta/senha) é recriado sozinho em outra
  máquina.
- **Mantenha os projetos dentro de `projects\`** (criada automaticamente a cada
  execução): eles viajam com a pasta portátil e as sessões abertas lá continuam
  funcionando quando a pasta aportar em outro caminho/máquina — localizações
  salvas apontando para a raiz anterior são remapeadas automaticamente
  (`launcher\root.marker`), e projetos movidos para `projects\` (de qualquer lugar)
  acordam pelo nome da pasta na próxima execução, incluindo estado do desktop e
  banco de sessões. Cada pasta sob `projects\` também ganha seu próprio
  repositório git na execução (`git init` quando ausente): o app resolve
  projetos pelo repositório git mais próximo, então sem essa fronteira pastas
  simples compartilhariam a identidade do projeto da raiz portátil (nome, cor).
  Projetos fora da pasta não têm essa rede de proteção: quando
  o caminho deles desaparece, as localizações salvas são removidas no boot (o
  histórico da sessão continua no `opencode.db`, e o app oferece "Escolher
  diretório" para reconectá-la).
- O launcher implanta o `AGENTS.md` universal (inglês, sem paths de máquina) em
  `home\.config\opencode\AGENTS.md` a cada execução — o slot global isolado do
  app. Idempotente; só sobrescreve arquivos que tenham a marca
  `<!-- OCDP-managed -->`, nunca um global de terceiros. Obs.: sessões abertas
  FORA da pasta portátil (instalação do sistema, outro terminal) usam a
  configuração real da máquina e não o veem. Notas pessoais/de-máquina:
  `AGENTS.user.md` ao lado — nunca lido nem escrito pelo launcher e fora do
  git; o `AGENTS.md` gerenciado avisa os agentes de que ele existe (não é
  auto-carregado: o agente o lê se presente).
- Mantenha `launcher\ocdp.ps1` salvo como **UTF-8 com BOM** (exigência do PS 5.1
  para os acentos do pt-BR).
- **Não lance `app-64\OpenCode.exe` direto**: fora do launcher ele roda contra
  o perfil real da máquina (dados separados e vazios) e pode disputar o serviço
  de fundo. Use sempre `launcher\OCDP.cmd`.
- Se alguma execução pré-v3 deixou o atalho `OpenCode` do Menu Iniciar apontando
  para o `.exe`, o launcher o reaponta sozinho para `launcher\OCDP.cmd` a cada
  execução (nunca cria o atalho: se você apagá-lo, ele continua apagado). Sob
  isolamento o próprio app não escreve mais no Menu Iniciar real.

## Licença

OCDP sob **MIT** (ver `LICENSE` na raiz). O 7-Zip embutido
(`launcher\7za.exe/.dll`) segue a própria licença do 7-Zip — ver
`launcher\LICENSE-7za.txt`. O `sqlite3.exe` embutido é domínio público — ver
`launcher\LICENSE-sqlite.txt`.

## Créditos

Desenhado por **Rafael Alt**; código gerado por modelos de IA.
Extrator: [7-Zip](https://www.7-zip.org/) 26.04 © Igor Pavlov (LGPL — ver
`launcher\LICENSE-7za.txt`). Reparo de estado salvo: SQLite 3.54 (domínio
público — ver `launcher\LICENSE-sqlite.txt`).
