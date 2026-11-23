---
name: voz
description: 'Liga e ajusta a voz do assistente de WhatsApp (assistente-wpp): áudio com a ElevenLabs, escolha de voz brasileira, amostras e teste. Use quando o dev digitar "/voz" ou disser "liga a voz do meu assistente", "troca a voz do meu assistente", "me mostra vozes brasileiras" ou "meu assistente pode mandar áudio?".'
---

<!-- Atalho instalado junto com a skill assistente-wpp (repositório bovi-assistente). -->

# /voz: a voz do seu assistente

Atalho da skill **assistente-wpp**. Antes de tudo, leia `~/.claude/skills/assistente-wpp/SKILL.md`, §5b (Voz) e §2
(regras). `$S` é `~/.claude/skills/assistente-wpp/scripts/assistente.ps1`. No macOS, rode pelo PowerShell 7:
`pwsh -NoProfile -File "$S" ...`.

Sem a skill assistente-wpp instalada, diga isso ao dev e aponte o README do repositório bovi-assistente. Pare aí.

Conduza como conversa, um passo por vez, em português, com cortesia. Nada aqui manda mensagem ao time.

1. **Onde está.** Rode `& $S help` e leia o item "Voz (áudio)". Diga ao dev, em uma frase, se a voz está ligada e
   qual voz está valendo.
2. **O que ela faz.** Explique em duas frases: o assistente responde em áudio a quem mandou áudio, ou quando
   pedem. Link, número, data e lista continuam em texto, logo depois do áudio. Sem a chave da ElevenLabs, tudo
   segue em texto, como hoje.
3. **Chave (só se faltar).** Ele cria a conta em https://elevenlabs.io e gera a chave em Perfil › API Keys. **Quem
   cola a chave é ele**, na linha `ELEVENLABS_API_KEY=` do `~/.assistente-wpp/assistente.env`. Abra esse arquivo no
   editor dele (VS Code: `code <arquivo>`; Windows sem VS Code: `notepad <arquivo>`; Mac: `open -e <arquivo>`). Não
   peça a chave no chat. Não a escreva em comando, arquivo de repositório ou mensagem. Espere ele dizer que salvou e
   confira com `& $S config` (deve aparecer `(definida)`).
4. **Voz.** Sem escolha, vale uma voz brasileira pelo gênero do assistente. Pergunte se ele quer ouvir outras:
   - `& $S vozes [-Genero feminino|masculino] [-Text "calma"]` lista as brasileiras mais usadas.
   - Gere amostras com a **mesma fala** para ele comparar: `& $S tts -Text "<fala>" -Out <arquivo>.ogg`, uma por
     voz. Mude `ASSISTENTE_VOZ_ID` só no ambiente daquela chamada.
   - Entregue os arquivos para ele ouvir. Ele também pode colar o link de uma voz que achou no site.
   - Gravar a escolhida: `& $S setup -VozId <id ou link>`.
   - `voz_reserva: true` no `tts` quer dizer que o plano dele não libera voz da biblioteca pela API: o áudio saiu
     numa voz padrão americana. Diga isso a ele.
5. **Ajuste fino (só se ele quiser).** No `.env`: `ASSISTENTE_VOZ_ESTABILIDADE`, `_SIMILARIDADE`, `_ESTILO`,
   `_VELOCIDADE` e `_TOM`. Ponto de partida natural: 0.30 / 0.80 / 0.45 / 1.08. Faça uma mudança por vez, com
   amostra.
6. **Teste de verdade.** Com o ok dele, mande um áudio curto para a conversa de avisos dele:
   `& $S send -Voice -Chat <ASSISTENTE_AVISO_JID efetivo de config> -Text "<fala>" -Operator claude -Token <n>`.
   O token vem de `& $D -Mode status` (despachante de pé) ou de `& $S lease acquire -Operator claude`. Neste caso,
   faça `release` no fim. `$D` é `scripts/assistente-despachante.ps1` da mesma skill.
7. **Desligar** quando ele pedir: `ASSISTENTE_VOZ=0` no `.env`. A chave fica guardada.

Feche com uma linha: voz ligada ou não, qual voz e como trocar depois (`/voz` de novo).
