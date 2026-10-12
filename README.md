# OCDP — OpenCode Desktop Portable

Launcher portátil do **OpenCode Desktop** para Windows: concentra todos os dados
do aplicativo dentro da própria pasta portátil (via junctions), mantém o app
atualizado a partir do feed oficial com verificação de integridade (sha512) e o
inicia em modo portátil.

> Requisitos: Windows 10+ (x64 ou arm64), PowerShell 5.1. O `curl.exe` (Win10 1803+)
> é usado quando disponível; há fallback automático sem ele.

## Uso

- **Duplo clique em `launcher\OCDP.cmd`** — faz tudo (portas → update → launch).
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
   validado por sha512), cria `app-64\` e `data\` ao lado e abre o app.
4. Configurações, sessões e credenciais ficam em `data\` — apagar `app-64\`
   é seguro (o launcher reinstala); apagar `data\` apaga seus dados de verdade.

## Estrutura

```
OCDP\
├── README.md           este arquivo
├── LICENSE             licença MIT do OCDP
├── AGENTS.md           regras universais para agentes (o launcher as implanta no slot global a cada run)
├── .gitignore          o que não vai para o GitHub (app-64, data, logs)
├── app-64\             o aplicativo (nome histórico; contém o build x64 ou arm64)
├── data\               TODOS os dados do OpenCode (destino das portas)
└── launcher\           tudo que é específico do OCDP (vai pro GitHub)
    ├── OCDP.cmd        ponto de entrada (define OPENCODE_DISABLE_AUTOUPDATE)
    ├── ocdp.ps1        o launcher (código/comentários em inglês, UI localizada)
    ├── ocdp.log        log de execuções (rotaciona para ocdp.log.old > 512 KB)
    ├── 7za.exe/.dll    extrator do instalador NSIS
    ├── LICENSE-7za.txt licença do 7-Zip (LGPL)
    ├── sweep-files.ps1 varredura de arquivos opencode/ocdp (somente leitura)
    └── sweep-system.ps1 varredura de registro/sistema (somente leitura)
```

### O que tem em `data\`

| Pasta | Origem original | Conteúdo | Dado de usuário? |
|---|---|---|---|
| `share-opencode` | `~\.local\share\opencode` | Banco `opencode.db` (sessões, mensagens, credenciais/API keys), logs, snapshots | 🔑 Sim |
| `config-opencode` | `~\.config\opencode` | `opencode.json` (settings), `service.json` | ⚠️ Sim |
| `state-opencode` | `~\.local\state\opencode` | Estado da execução atual (PID, porta, senha local) | ⚠️ Volátil |
| `ai.opencode.desktop` | `%APPDATA%\ai.opencode.desktop` | Perfil Electron: rascunhos (drafts), Local Storage, cookies, logs, caches, `cli\opencode-cli.exe` | ⚠️ Parcial |
| `cache-opencode` | `~\.cache\opencode` | Cache (ex.: `rg.exe`) — apagável | ❌ Não |

## Como funciona (resumo)

1. **Trava de instância** (mutex por raiz portátil): um segundo `OCDP.cmd`
   simultâneo falha rápido, sem competir no download/swap.
2. **Encerra qualquer processo `*opencode*`** (app, sidecar "opencode-cli",
   TUI, instalador) — evitam-se arquivos travados na migração/swap — e
   esvazia o raspeiro de sessão (`%TEMP%\opencode`).
3. **Portas (junctions)**: o app procura seus dados em endereços fixos
   (`%APPDATA%\ai.opencode.desktop`, `~\.config\opencode`, etc.). O script cria
   junctions nesses endereços apontando para `data\`. É sempre o MESMO arquivo
   físico — apagar conteúdo pela porta apaga o dado real.
4. **Updater nativo desabilitado de propósito** (3 camadas):
   `OPENCODE_DISABLE_AUTOUPDATE=1` (env), `opencode.json` (`update: disable` /
   `autoupdate: false`) e remoção de `resources\app-update.yml`. Atualizações
   vêm SOMENTE deste script (feed oficial + sha512).
5. **Atualização**: lê o `latest.yml` oficial (com retry e TLS 1.2), compara
   versões, baixa o instalador (curl com fallback), **valida sha512 + tamanho**,
   extrai com 7za para `app-64.new`, remove `app-update.yml`, faz o swap
   (`app-64` → `app-64.old` → remoção com retries). Pastas travadas geram erro
   claro, nunca corrupção silenciosa; se a aplicação da nova versão falhar no
   meio do swap, a instalação anterior é restaurada automaticamente (rollback).
6. **Lançamento** de `app-64\OpenCode.exe` — a janela do launcher **fecha
   sozinha** (o app roda destacado do console); em erro, ela permanece aberta
   com a mensagem legível.

## Solução de problemas

| Sintoma | Explicação / ação |
|---|---|
| "encerrando processos relacionados..." ao abrir | Normal (por design): evita conflito de arquivos. |
| "outra instância do OCDP já está em execução" | Espere um instante e rode de novo. |
| "pasta antiga/preparação ainda travada" | Feche os processos (`OpenCode`, `opencode-cli`) e tente de novo. |
| "não foi possível ler o feed de atualização" | Veja `launcher\ocdp.log` — a causa real (DNS/TLS/proxy) fica registrada. |
| "não foi possível encerrar: ..." | Feche manualmente pelo Gerenciador de Tarefas e rode de novo. |
| Onde ver problemas | `launcher\ocdp.log` (launcher) e `data\share-opencode\log\opencode.log` (app). |

## Notas importantes

- **Nunca apague o conteúdo de `data\`** achando que é "cópia" das pastas do C:
  — as pastas do C: são portas; o dado vive aqui.
- Apagar *uma porta* é seguro: a próxima execução recria. Para remover só a
  porta, use `rmdir "C:\caminho\da\porta"` (nunca "apagar conteúdo").
- **Mover a pasta OCDP inteira é seguro**: as portas são relinkadas sozinhas.
- O launcher implanta o `AGENTS.md` universal (inglês, sem paths de máquina) em
  `~\.config\opencode\AGENTS.md` a cada execução — idempotente; só sobrescreve
  arquivos que tenham a marca `<!-- OCDP-managed -->`, nunca um global de
  terceiros. Notas pessoais/de-máquina: `AGENTS.user.md` ao lado — nunca lido
  nem escrito pelo launcher e fora do git; o `AGENTS.md` gerenciado avisa os
  agentes de que ele existe (não é auto-carregado: o agente o lê se presente).
- Mantenha `launcher\ocdp.ps1` salvo como **UTF-8 com BOM** (exigência do PS 5.1
  para os acentos do pt-BR).
- Lançar `app-64\OpenCode.exe` direto funciona (as portas já existem), mas pula
  a checagem de update — prefira `launcher\OCDP.cmd`.
- Se o app recriar o atalho `OpenCode` do Menu Iniciar apontando para o `.exe`,
  o launcher o reaponta sozinho para `launcher\OCDP.cmd` a cada execução (nunca
  cria o atalho: se você apagá-lo, ele continua apagado).

## Licença

OCDP sob **MIT** (ver `LICENSE` na raiz). O 7-Zip embutido
(`launcher\7za.exe/.dll`) segue a própria licença do 7-Zip — ver
`launcher\LICENSE-7za.txt`.

## Créditos

Criado por **mimo-flash**; aprimorado por **glm-flash** e **DeepSeek**.
Extrator: [7-Zip](https://www.7-zip.org/) 26.04 © Igor Pavlov (LGPL — ver
`launcher\LICENSE-7za.txt`).
