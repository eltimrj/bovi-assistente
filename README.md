# bovi-assistente

Um assistente de WhatsApp para cada dev do time, rodando no Claude Code.

Ele atende os colegas pelo **seu** WhatsApp: responde quem pergunta do estado de um PR, card ou story (sempre
conferido na fonte e com link), lê os grupos do time e te traz o que importa. Também te avisa quando uma sessão sua
do Claude Code termina e está esperando por você.

**Você batiza o seu assistente e escolhe a personalidade dele.** O gênero ("ela" ou "ele") é opcional; sem
escolha, ele fala de forma neutra. Há seis personalidades prontas, e você pode ajustar quando quiser, só pedindo.
Ou pode não mexer nunca: ele funciona bem do jeito que vem.

| Personalidade | Com você | Com o time |
|---|---|---|
| Objetiva (padrão) | direta e cortês, sem enfeite nem humor | igual |
| Cordial | calorosa e acolhedora, mas curta | igual |
| Técnica | dev para dev: termos exatos, listas, links | igual |
| Leve | uma frase bem-humorada quando cabe | igual |
| Amorosa | sua webnamorada particular, pela zoeira | cordial |
| Parça | sem polimento: gíria, palavrão e zoeira | leve, sem palavrão |

O que não muda em nenhuma personalidade é a **objetividade**: mensagem clara, com o próximo passo, e sem zoeira
em urgência, produção ou erro. Com o time, cortesia sempre.

## Onde ele roda (leia antes de instalar)

- **No seu Windows ou no seu Mac, sempre que você estiver logado nele.** O vigia religa o assistente no login e a
  cada 3 minutos: no Windows, pelo Agendador; no Mac, por um LaunchAgent (`~/Library/LaunchAgents`). Não precisa
  deixar nenhuma sessão do Claude aberta.
- **Não quer que rode nesta máquina?** Desative: diga "desliga meu assistente" (fica desligado até você religar,
  mesmo reiniciando) ou desinstale com `install.ps1 -Remover`. Depois, instale e ligue no computador de trabalho.
- **Um computador só por conta de WhatsApp.** Com dois ligados na mesma conta, ele responde em dobro.

## Como funciona

```
WhatsApp ── app WhatsApp MCP ── detector (sem IA, a cada 30 s)
                                     │ mensagem nova do time
                                     ▼
                              despachante ── abre o Claude sem tela ── lê, confere, responde ── fecha
                                     ▲
                              vigia (Agendador do Windows ou LaunchAgent do Mac, a cada 3 min): mantém tudo
                              de pé e te avisa se cair
```

- Em repouso, o consumo é quase zero: o Claude só abre quando chega mensagem do time.
- Ele só fala com quem você colocou na sua lista do time. Ninguém de fora é lido nem respondido.
- Quando você mesmo escreve numa conversa, ele fica em silêncio ali por 15 min.
- Ele só conversa: merge, card, acesso ou recado a terceiros, só com o seu ok.
- Telefones, a lista do time e a sua personalidade ficam só no seu computador (`~/.assistente-wpp/`), nunca
  em repositório.

## Requisitos

- **Windows** (Windows PowerShell 5.1, que já vem no sistema) **ou macOS** com o **PowerShell 7.5+**:
  `brew install powershell`. É o mesmo código nos dois: no Mac ele roda pelo `pwsh`.
- [**Claude Code**](https://claude.com/claude-code) instalado e logado (VS Code, terminal ou T3 Code).
- App [**WhatsApp MCP**](https://github.com/BrOrlandi/whatsapp-mcp-local), aberto e com o seu WhatsApp
  conectado.
- `gh` (GitHub CLI) logado, para o assistente conferir PRs.
- Opcional, para a voz: uma conta na [ElevenLabs](https://elevenlabs.io) (a chave é sua) e o `ffmpeg`
  (`winget install Gyan.FFmpeg` / `brew install ffmpeg`). Sem o ffmpeg a voz funciona, mas sem o ajuste de tom.

## Instalar

No **Windows**:

```powershell
git clone https://github.com/eltimrj/bovi-assistente.git
cd bovi-assistente
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

No **Mac**:

```bash
brew install powershell
git clone https://github.com/eltimrj/bovi-assistente.git
cd bovi-assistente
pwsh ./install.ps1
```

No Mac, o instalador grava o vigia em `~/Library/LaunchAgents/local.assistente-wpp.vigia.plist` e os hooks do aviso
de sessão chamando o `pwsh`. Os alertas do vigia aparecem como notificação do macOS.

Depois, abra o Claude Code e diga:

> configure meu assistente de WhatsApp

Ele te guia: o nome do assistente, a personalidade, quem é do time, quanta autonomia ele tem e onde você programa.
Leva uns 10 minutos.

## Manual: o que está ligado

Para ver tudo o que o assistente faz e o que está ativo ou não neste momento, diga ao Claude:

> /assistente-wpp help

ou "ajuda do assistente". No terminal, sem o Claude:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\assistente-wpp\scripts\assistente.ps1" help
```

No Mac:

```bash
pwsh ~/.claude/skills/assistente-wpp/scripts/assistente.ps1 help
```

Ele lista cada função por área (identidade, conexão, atendimento, funcionamento, aviso de sessão e
plataforma) e mostra para cada uma se está `[ativo]`, `[inativo]` ou pedindo `[atenção]`, com o jeito de mudar.
Você também pode escrever "ajuda" na conversa consigo mesmo no WhatsApp: o assistente responde ali com um resumo.
Para usar em script, há o `help -Json`.

## No dia a dia

| Você quer | Diga ao Claude, ou faça |
|---|---|
| Ver o que está ligado | "/assistente-wpp help" ou "ajuda do assistente" |
| Ajustar a personalidade | "deixa meu assistente mais direto", "pode usar emoji" |
| Trocar de personalidade | "muda meu assistente para a personalidade técnica" |
| Trocar o nome | "troca o nome do meu assistente para X" |
| Mandar um recado | "manda pro Fulano que o PR está pronto", ou escreva isso na conversa consigo mesmo no WhatsApp |
| Pôr alguém novo no time | "adiciona a Fulana na equipe do meu assistente" |
| Desligar por um tempo | "desliga meu assistente" (`pause on`); para religar, "religa" |
| Só triagem, sem responder sozinho | "deixa meu assistente só em triagem" |
| Ligar a voz | "liga a voz do meu assistente": ele abre o `.env` para você colar a chave da ElevenLabs; depois responde em áudio a quem mandar áudio |
| Escolher a voz | "me mostra vozes brasileiras" (ele gera amostras para você ouvir) ou "troca a voz para <link da ElevenLabs>" |
| Ver horários em outro fuso | "usa o fuso GMT+1 nos meus horários". O padrão é GMT-3, o fuso do time; para o time, os horários seguem em GMT-3 e, se os fusos forem diferentes, saem com o fuso escrito ao lado |

## Aviso de sessão

Quando uma sessão sua do Claude Code passa de 1 minuto e termina, ou fica esperando a sua autorização ou resposta,
o assistente te avisa no WhatsApp com o título da sessão e um jeito de voltar a ela:

- **VS Code:** um link que abre a sessão.
- **Terminal (CLI):** a pasta e o comando `claude --resume <id>`.
- **T3 Code:** o título da conversa e a pasta. Ainda não testado com o T3 (veja o `SKILL.md`, §7b).
- **Remote Control ligado:** também o link para abrir no celular.

Desligar: `ASSISTENTE_AVISO_SESSAO=0` em `~/.assistente-wpp/assistente.env`.

## Voz (opcional)

O assistente pode responder **em áudio** a quem mandar áudio (ou quando pedirem), com uma voz da
[ElevenLabs](https://elevenlabs.io). Link, número, data e lista continuam em texto, logo depois do áudio. A chave e a
voz escolhida ficam só no seu `~/.assistente-wpp/assistente.env`; nada disso vai para o repositório.

- **Sem escolher voz**, ele usa uma das vozes padrão da ElevenLabs pelo gênero do assistente. Elas funcionam em
  qualquer plano, mas são americanas falando português.
- **Vozes brasileiras** soam bem mais naturais: `assistente.ps1 vozes` lista as mais usadas, e
  `assistente.ps1 tts -Text "…"` gera uma amostra sem enviar nada. As da biblioteca podem exigir plano pago.
- **Ajuste fino** (estabilidade, estilo, velocidade e tom) no `.env`. Um ponto de partida natural: `0.30 / 0.80 /
  0.45 / 1.08`.
- O áudio chega como **arquivo de áudio**, não como nota de voz: o app WhatsApp MCP ainda não manda nota de voz.

## Atualizar

```powershell
git pull
powershell -ExecutionPolicy Bypass -File .\install.ps1     # Windows
pwsh ./install.ps1                                          # Mac
```

A sua configuração, a equipe e a personalidade não são tocadas.

## Desinstalar

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Remover     # Windows
pwsh ./install.ps1 -Remover                                          # Mac
```

Remove a skill, o vigia (a tarefa agendada no Windows, o LaunchAgent no Mac) e os hooks. A pasta `~/.assistente-wpp` fica; apague à mão se quiser.

## Testes

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\assistente.tests.ps1     # Windows
pwsh -NoProfile -File ./tests/assistente.tests.ps1                                    # Mac
```

Rodam contra um app WhatsApp falso, num diretório temporário, sem tocar na sua configuração. No Mac, os testes do
instalador gravam o LaunchAgent numa pasta temporária e não chamam o `launchctl`.

## Estrutura

```
install.ps1                         instalador (skill, vigia, hooks), no Windows e no Mac
skills/assistente-wpp/
  SKILL.md                          o que o Claude lê: onboarding, regras, personalidade, operação
  references/OBJETIVIDADE.md        o núcleo de toda mensagem (nenhuma personalidade muda)
  references/PROTOCOLO.md           quem atender, grupos, espera, sigilo
  references/personalidades/        os quatro presets
  scripts/assistente.ps1            utilitários sem IA: envio com travas, detector, equipe, volante
  scripts/assistente-despachante.ps1  abre o Claude a cada lote de mensagens
  scripts/assistente-vigia.ps1      mantém o despachante de pé e avisa se cair
  scripts/aviso-sessao*.ps1         aviso de sessão terminada (hooks do Claude Code)
  scripts/plataforma.ps1            o que muda entre Windows e Mac (processos, notificação, LaunchAgent)
exemplos/equipe.exemplo.json        formato da lista do time (números fictícios)
tests/                              testes com app WhatsApp falso
```
