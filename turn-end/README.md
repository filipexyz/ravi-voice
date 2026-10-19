# jev-turn-end — encerramento por Jev (nativo)

O Ravi Voice calcula o **D0 acústico local** e, quando o agente termina de falar, chama o **Jev
direto do app** (sem sidecar) para decidir se a conversa pode fechar. Em **shadow**, só registra.
Em **live**, fecha apenas quando o D0 libera, o Jev confirma, a confiança passa e o motivo está
na allowlist.

## Status agora

- **Nativo**: o app fala com a Vercel AI Gateway ou com a API direta do Jev; não usa mais o
  sidecar `127.0.0.1:8791`.
- **Live por padrão quando existe chave**. Sem chave, o app loga
  `turn-end: desativado (sem chave Jev...)` e não fecha por este caminho.
- Fail-safe: erro, timeout, JSON inválido, estado `continua` ou baixa confiança → `wait`.
- `close_session` explícito e `closeAfterRequestSeconds` continuam como estavam.

## Arquivos

| arquivo | papel |
|---|---|
| `Sources/RaviVoice/JevTurnEndProvider.swift` | chamada nativa (Vercel ou TypeSafe), resolução de chave/base/model |
| `Sources/RaviVoice/TurnEnd.swift` | D0, política, serviço, log e retry pós-gate |
| `Sources/RaviVoice/LiveSession.swift` | integração com o tick de 100 ms |
| `turn-end/server.ts` | **legado**: sidecar HTTP da PoC; não é mais usado pelo app |
| `turn-end/report.ts` | lê `turn-end.jsonl` e compara D0 sozinho × D0+Jev |

## Config do app

Bloco `turnEnd` em `~/.config/ravi-voice/config.json`. O app lê os defaults e sobrescreve só o
que estiver no arquivo.

### Vercel AI Gateway (padrão)

```json
"turnEnd": {
  "enabled": true,
  "shadow": false,
  "allowLiveClose": true,
  "provider": "vercel",
  "model": "typesafe-ai/jev",
  "baseURL": "https://ai-gateway.vercel.sh/v4/ai/evaluation-model",
  "apiKeyEnv": "AI_GATEWAY_API_KEY",
  "liveReasonCodes": ["EXPLICIT_CLOSE", "STATE_ENDED", "WAITING_ASYNC"],
  "timeoutMs": 1500,
  "minIntervalMs": 2000,
  "d0": { "outputThreshold": 0.08, "inputThreshold": 0.08, "eosQuietMs": 300, "userGuardMs": 500 },
  "policy": { "minStateProb": 0.7, "minCompleteProb": 0.5, "explicitProb": 0.55, "waitingQuietMs": 3000 }
}
```

`model`, `baseURL` e `apiKeyEnv` são opcionais; se omitidos, valem os padrões do provider.
A chave fica em `~/.config/ravi-voice/jev.env` (0600):

```
AI_GATEWAY_API_KEY=vck_...
```

### API direta do Jev (TypeSafe)

```json
"turnEnd": {
  "enabled": true,
  "shadow": false,
  "allowLiveClose": true,
  "provider": "typesafe",
  "model": "jev-1.13.0",
  "baseURL": "https://api.typesafe.ai/v1/systemone",
  "apiKeyEnv": "TYPESAFE_API_KEY"
}
```

No `jev.env`:

```
TYPESAFE_API_KEY=...
```

O provider `typesafe` usa perguntas booleanas no tipo `noul`; o `vercel` usa `boolean`.
Aliases de `provider`: `jev`, `systemone`, `direct` → TypeSafe; qualquer outro → Vercel.

### Chave: ordem de resolução

1. `apiKey` no bloco (não recomendado);
2. ambiente (`apiKeyEnv` e `JEV_API_KEY`);
3. `~/.config/ravi-voice/jev.env`;
4. `~/.ravi/.env`.

Sem chave para o provider escolhido, o provider nativo não é criado e o app não usa o Jev.

## Shadows e teste ativo

- `shadow=true` → só registra; nunca fecha.
- `shadow=false` + `allowLiveClose=true` → live; motivos precisam estar em `liveReasonCodes`.
- `liveUntil` é opcional; `null`/ausente = sem prazo.
- `allowLiveClose=false` é uma segunda trava: mesmo em live, não fecha.

Para desligar o fechamento nativo: `shadow=true` ou `allowLiveClose=false`, e reinicie o app.

## Retry pós-gate

Se o Jev decidir `close` mas o gate ainda bloquear (ex.: `user_guard` de 500 ms depois da última
fala do usuário), o app **não cancela de vez**:

- registra `fechamento adiado (<motivo>)` com `output_level`, `input_level`, `eos_quiet`,
  `user_guard` ou `pending_work`;
- reavalia a cada ~400 ms, por até 5 s, até o gate abrir;
- quando abre, loga `gate liberou; reavaliando` e manda um novo candidato ao Jev;
- candidato espera 200 ms sem novo delta de transcrição para não enviar snippet cortado.

## Logs e relatório

| log | conteúdo |
|---|---|
| `~/Library/Logs/RaviVoice/turn-end.jsonl` | eventos do app: `candidate`, `user_speech`, `session_end` |
| `~/Library/Logs/RaviVoice/turn-end-provider.jsonl` | legado do sidecar |
| `~/Library/Logs/RaviVoice/jev-turn-end.log` | stdout/stderr do sidecar legado |

Cada `candidate` tem `mode`, `provider_decision`, `decision` (política do app), `app_decision`,
`acted`, `latency_ms`, `reason_code`, `signals` e `snippets`.

```bash
cd /Users/luis/Dev/filipelabs/ravi-voice
bun run turn-end/report.ts
```

## Build/install

```bash
swift build
make install     # build release, assina e reinicia o app
```

O sidecar não é necessário. O LaunchAgent `bot.ravi.voice.jev` pode ser desligado:

```bash
launchctl bootout gui/501/bot.ravi.voice.jev
```
