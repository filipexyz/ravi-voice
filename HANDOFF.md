# Ravi Voice — handoff

## 2026-11-10 — proteção de avisos do voice-observer (local, sem instalação)

Worktree própria `ravi-voice-observer-attention`, branch `feat/voice-observer-safe-announcements`,
base remota `e215d8a`. O commit local anterior `a2035e6` (knock detector) foi excluído
da branch de publicação. O checkout principal e suas alterações de outro trabalho foram
preservados. Escopo autorizado: impedir que avisos do observer entrem por cima de fala.

- `voice-observer` é identificado por `VoiceMessage.fromAgent`, não pelo texto.
- Conversa ocupada: descartar aviso sem guardá-lo para ressurgir no contexto.
- App ocioso: sessão de anúncio isolada, sem chimes/histórico/tools de ação; microfone
  usado localmente para um segundo de silêncio contínuo antes da submissão.
- Guard compartilhado entre captura e playback: fala detectada, amostra inválida ou
  captura interrompida cancela terminalmente; áudio enfileirado é limpo no encerramento.
- Outros remetentes têm prioridade, cancelando a notificação isolada antes do fluxo normal.
- Testes focados do gate usam timestamps artificiais, sem microfone nem rede.

Não houve install, restart, alteração de config do Luís ou renovação do experimento.
Publicação deve usar `ravi pr publish` autenticado quando o runtime atualizado disponibilizar
o comando; não usar upload manual por Git Data API. A ativação do detector de assuntos
abandonados e a renovação por prazo ainda dependem da etapa posterior, após instalação
e validação do caminho real. Ver resultado de testes no registro da PR/commit.

Limite explícito: as garantias são relativas à fala detectada e às amostras da captura;
há latência de hardware/processamento. Validação acústica no Mac continua pendente.

Atualizado em 2026-10-18 22:00 (BRT), a partir da sessão Claude Code `d0ca769b-f138-4fcc-a8cc-868500614940`
em `~/.claude/projects/-Users-luis-Dev-filipelabs-ravi-voice/`.

## O que é

Agente de voz que vive na menu bar do Mac (sem Dock), fala com o Luís via OpenAI `gpt-live-1`
(full-duplex), abre com um toque no ⌘ direito e fecha sozinho depois de 60s de silêncio.
Ele conversa com as sessões do Ravi pelo gateway HTTP local + Swift SDK.

- App: `/Users/luis/Dev/filipelabs/ravi-voice` (Swift Package, sem repo git próprio)
- LaunchAgent: `bot.ravi.voice` → app em `~/Applications/RaviVoice.app`
- Config: `~/.config/ravi-voice/config.json`
- Memória entre conversas: `~/.config/ravi-voice/memory.json` (0600)
- Context key do Ravi: `~/.config/ravi-voice/ravi-context.key` (`rctx_*`, expira ~2027-01-15)
- Logs: `~/Library/Logs/RaviVoice/ravi-voice.log` e `transcripts.log`
- Fonte: `Sources/RaviVoice/` (LiveSession, AudioIO, Overlay, IdleTracker, ConversationMemory,
  RaviGateway, RaviBridge, RaviTools, VoiceInbox, NATSPublisher, Hotkey, AppController, CLI)
- Scripts: `scripts/build-app.sh`, `scripts/install.sh`, `scripts/ravi-setup.sh`
- Manifesto do app Ravi: `ravi/ravi.app.json` (op `ravi voice say`)

## Estado atual

- **App + voz** (hotkey, GPT-Live, overlay, idle, memória) — entregue 2026-10-18.
- **Integração Ravi** (gateway, contexto de sessões, tools `ravi_*`) — entregue 2026-10-18.
- **Ponte `ravi.voice`** — app `voice` + trigger shell `ravi-voice-inbox` (id `d9e9d1aa`) em
  `ravi.voice.>`; agentes respondem por `ravi voice say --execute --reply-to <id>`.
- **Memória entre conversas** — `ConversationMemory.swift` + `memory.json`; investigação pedida
  em 00:39Z sobre "não lembra do chat anterior quando desligo" mexeu em
  `ConversationMemory.swift`/`AppController.swift` (21:45).
- **PR aberto no ravi.bot**: `filipexyz/ravi#701` — "feat(triggers): optional cooldown and
  debounce, so bursts are batched instead of dropped". Push com `--no-verify` autorizado;
  Quality Gate (suíte inteira) estava rodando no fechamento deste handoff.
- **Fim de turno (nativo, live)** — 2026-10-19: `JevTurnEndProvider.swift` chama o Jev
  **direto do app**, sem sidecar. D0 local + política em `TurnEnd.swift`; retry pós-gate em
  `LiveSession.swift`. Provider/model/base/chave configuráveis no bloco `turnEnd`:
  `provider` (`vercel` ou `typesafe`/`jev`), `model`, `baseURL`, `apiKeyEnv`; sem chave o
  provider não é criado e o app não fecha por Jev. Chave em
  `~/.config/ravi-voice/jev.env` (0600). O sidecar `turn-end/server.ts` e o LaunchAgent
  `bot.ravi.voice.jev` ficaram **legados**; o app não os consulta mais. App reinstalado às
  03:25Z; log: `turn-end: LIVE nativo até sem prazo; provider=vercel model=typesafe-ai/jev`.
  Retry: gate bloqueado não cancela de vez; reavalia a cada ~400 ms por até 5 s, espera 200 ms
  de transcrição estável e então manda novo candidato. Motivo do gate é logado. 43 testes
  passavam antes desta mudança; depois dela rodei só `swift build`/install, sem suíte.
  Relatório: `bun run turn-end/report.ts`. Replay de 111: D0 sozinho 19/33 cortes; D0+Jev
  1/33 em 2 s e 4/33 em 3,5 s. Cron `c3144a6c` reporta no fim da janela de shadow.

## Mudanças pendentes de build/install (código pronto, não buildado)

> **Bloqueio**: `swift build` e `make test` estão sendo bloqueados pelo hook do Ravi com
> "Remote gateway authentication failed". Precisa corrigir antes de qualquer install.

1. **Sons suavizados** (`AppController.swift`):
   - Start: `"Tink"` → `"Pop"` (suave, sem susto)
   - End normal: `"Bottle"` → `"Blow"` (gentil)

2. **CloseSessionTool** (`Tools.swift` + `AppController.swift`):
   - Nova ferramenta `close_session` registrada no ToolRegistry
   - Permite encerrar a sessão de voz dizendo "encerra", "tchau", "para"
   - Instrução adicionada ao `defaultInstructions` em `Config.swift`

3. **Galeria de carinhas** (`design/faces-gallery.html`):
   - 4 designs animados: Atual, Suave, Linear, Onda
   - Estados: conectando, ouvindo, falando, pensando, mudo
   - Pronto para `ravi pages ship --html design/faces-gallery.html --title "Ravi Voice — Galeria de Carinhas" --visibility protected_link`
   - **Requer turno WhatsApp** (permissão negada em turno background)

4. **Nova sessão Claude Code** com Opus 4.7:
   - Sem conflito com sessão atual: abrir terminal novo no projeto
   - Comando: `cd /Users/luis/Dev/filipelabs/ravi-voice && claude --model claude-opus-4-7`

## Como rodar e testar

```bash
make test      # testes unitários (hotkey, idle, config, tools)
make install   # build + assinatura + ~/Applications/RaviVoice.app + LaunchAgent
make restart   # reinicia o agente
make logs      # log + transcrições ao vivo
make run       # roda o .app do build/ em foreground
RaviVoice --ravi-context   # imprime o contexto que a próxima sessão de voz recebe
```

## Gotchas conhecidos

- Trigger do Ravi tem cooldown mínimo de 1s; `RaviVoice say` espaça publicações em 1,2s.
- Saída de `ravi … --json` piped corta em 64 KB — use listagem em texto.
- Ops mutantes de app exigem `--execute`.
- A chave da OpenAI vem de `openaiApiKey` no config, `OPENAI_API_KEY` no ambiente ou
  `~/.ravi/.env`, nessa ordem.
- `ravi context issue` da context key expira em ~2027-01-15 (limitada pela admin key de 90d).

## Próximos passos candidatos

1. Fechar o PR 701 (CI + merge).
2. Validar a memória entre conversas na prática (fechar/reabrir e conferir `memory.json`).
3. Página de apresentação do app para um heavy user do Ravi (pedido em 00:23Z).
