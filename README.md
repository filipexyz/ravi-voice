# Ravi Voice

Agente de voz que vive no Mac (menu bar, sem Dock) e conversa com você pelo **GPT-Live 1**
(`gpt-live-1`, full-duplex). Toque o **⌘ direito** sozinho pra abrir uma sessão; ela fecha
sozinha depois de 60s sem ninguém falar, ou quando você toca o hotkey de novo.

## Rodar

```bash
make install     # build + assina + ~/Applications/RaviVoice.app + LaunchAgent (login, KeepAlive)
make restart     # reinicia o agente
make logs        # log + transcrições ao vivo
make uninstall
make test        # testes unitários (hotkey, idle, config, tools)
make run         # roda o .app do build/ em foreground
```

Na primeira vez, libere em **Ajustes › Privacidade e Segurança**:
- **Monitoramento de Entrada** → Ravi Voice (pro hotkey global; depois `make restart`)
- **Microfone** → Ravi Voice (pedido na primeira sessão)

A chave da OpenAI vem de `openaiApiKey` no config, `OPENAI_API_KEY` no ambiente ou do
`~/.ravi/.env` do daemon do Ravi, nessa ordem.

## Config

`~/.config/ravi-voice/config.json` (criado no primeiro boot; menu › Recarregar config):

| campo | default | |
|---|---|---|
| `hotkey` | `rightCommand` | modificador sozinho (`rightOption`, `rightShift`, `rightControl`, `fn`, …) ou combo (`ctrl+option+space`) |
| `hotkeyWhileActive` | `end` | `end` fecha a sessão, `mute` alterna o mic |
| `idleTimeoutSeconds` | `60` | silêncio dos dois lados, sem backend trabalhando |
| `voice` | `marin` | fixa por sessão |
| `backendModel` | `gpt-6-luna` | modelo da delegação (Responses) |
| `webSearch` | `true` | web search hospedado no backend |
| `overlay` | `true` | carinha + legenda no topo da tela durante a sessão |
| `sounds` | `true` | sons de início/fim |
| `memoryEnabled` | `true` | a próxima conversa recebe o histórico das anteriores |
| `memoryHours` | `12` | até quanto tempo atrás o histórico vale |
| `memoryMaxTokens` | `6000` | quanto do limite de 8.192 tokens do `input` o histórico usa |
| `instructions`, `backendInstructions` | pt-BR | prompts da voz e do backend |

O ⌘ direito só dispara num toque limpo (< 0,5s, sem outra tecla no meio), então ⌘C com o
⌘ direito continua funcionando normal.

## Como funciona

```
⌘ direito ─▶ HotkeyMonitor (CGEventTap, listen-only)
                 │
                 ▼
AudioIO (AVAudioEngine + voice processing/AEC) ◀──▶ LiveSession ◀──▶ wss://api.openai.com/v1/live/sessions
  mic → PCM16 24kHz, 100ms chunks                    │  session.start / input_audio.append / output_audio.delta
  speaker ← PCM16 24kHz                              │  response.event (delegação Responses → function_call)
                                                     ▼
                                     ToolRegistry (current_time, close_session, ravi_*)
```

- `Sources/RaviVoice/LiveSession.swift` — protocolo GPT-Live, ciclo de vida, loop de tools.
- `IdleTracker.swift` — inatividade = sem transcrição/áudio não-silencioso; delegação ou tool
  pendente segura a sessão viva (uma tool lenta não derruba a conversa).
- `Overlay.swift` — painel flutuante: anel verde reage ao seu mic (ouvindo), boca mexe com o
  áudio (falando), olhar de lado + arco laranja (pensando), vermelho (mutado).
- Logs em `~/Library/Logs/RaviVoice/` (`ravi-voice.log`, `transcripts.log`).
- `RaviVoice --start` abre uma sessão no boot; `--snapshot <dir>` renderiza o overlay em PNG.

## Memória entre conversas

Cada conversa é uma sessão nova do GPT-Live; sem histórico ela começaria do zero. As falas
(montadas por pessoa, então falar ao mesmo tempo não quebra frases) vão para
`~/.config/ravi-voice/memory.json` (0600), e o `session.start` seguinte leva as das últimas
`memoryHours` como `session.input`, dentro de `memoryMaxTokens`, mais uma nota de quando a
conversa anterior terminou. Nada fica gravado na OpenAI (o fork de sessão exigiria `store: true`
e herdaria as instruções antigas). No primeiro boot com memória, o histórico é importado do
`transcripts.log`. Menu › "Esquecer conversas anteriores" apaga.

## Ravi

O agente fala com o daemon do Ravi pelo gateway HTTP local, usando o Swift SDK gerado
(`../ravi.bot/packages/ravi-os-swift-sdk`, dependência local do pacote).

- **Contexto na abertura:** as `raviRecentSessions` (6) sessões mais recentes, com as últimas
  `raviMessagesPerSession` (4) mensagens de cada uma (via `sessions recap`), entram nas
  instruções do `session.start`. O snapshot é atualizado a cada 2 min em background, então a
  sessão abre sem esperar. Eventos de sistema, markdown e caminhos de anexo são filtrados.
- **Tools do backend:** `ravi_list_sessions`, `ravi_session_recap`, `ravi_send_message`.
- `RaviVoice --ravi-context` imprime exatamente o contexto que a próxima sessão vai receber.

### Ponte `ravi.voice` (pedidos e mensagens de outros agentes)

```
voz ──ravi_send_message──▶ sessions send <sessão>  (+ instrução implícita de retorno)
                                │
agente ──ravi voice say --execute [--reply-to <id>] --text "…"   (app Ravi `voice`)
                                │  RaviVoice say → NATS ravi.voice.message
                                ▼
trigger shell `ravi-voice-inbox` (ravi.voice.>) → RaviVoice deliver → ~/.config/ravi-voice/inbox/
                                ▼
app no Mac: conversa aberta → fala na hora; fechada → acorda (som), fala e fecha depois de 30s
```

- **Pedido por voz:** a mensagem vai com uma instrução de retorno: responder com
  `ravi voice say --execute --reply-to <id>` e terminar o turno com `@@SILENT@@`, pra não postar
  no chat anexado da sessão. Depois de mandar, a voz avisa que volta quando tiver a resposta e
  a conversa fecha (`closeAfterRequestSeconds`, 5s de silêncio). A resposta reabre a conversa.
- **Qualquer agente** pode falar com você: `ravi voice say --execute --text "..."`. Quem mandou é
  identificado pela própria context key do agente (`context whoami`), não por argumento.
- Mensagens com mais de `wakeMaxAgeMinutes` (30) não acordam a voz; entram no contexto da
  próxima conversa. `wakeOnMessages: false` desliga o despertar.
- A caixa de entrada é um diretório: mensagens que chegam com o app reiniciando ficam esperando.
- O trigger tem cooldown mínimo de 1s no Ravi (eventos dentro dele são descartados); o
  `RaviVoice say` espaça as publicações em 1,2s pra nenhuma cair nele.
- Instalar/remover o lado do Ravi (app + trigger): `scripts/ravi-setup.sh` / `scripts/ravi-setup.sh remove`.

### Context key

O gateway exige uma key `rctx_*`. A do Ravi Voice é uma filha da admin key, só com o necessário:

```bash
ravi daemon init-admin-key        # se não houver admin key válida (salva em ~/.ravi/credentials.json)
umask 077
ravi context issue ravi-voice --ttl 89d --json \
  --allow 'read:sessions:list,read:sessions:recap,read:sessions:read,mutate:sessions:send,access:session:*' \
  | jq -r .contextKey > ~/.config/ravi-voice/ravi-context.key
make restart
```

A TTL é limitada pela admin key (90 dias): quando expirar, repita os comandos. Revogue com
`ravi context revoke <contextId>`. O endereço do gateway vem de `RAVI_HTTP_HOST`/`RAVI_HTTP_PORT`
no `~/.ravi/.env` (ou `raviGatewayURL` no config); `raviEnabled: false` desliga a integração.
