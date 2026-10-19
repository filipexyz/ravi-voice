/**
 * jev-turn-end — provedor externo de fim de turno para o Ravi Voice.
 *
 * O app só chama depois que o D0 acústico confirmou o fim da fala. Este processo:
 *   1. recebe sinais + últimos trechos (nunca áudio);
 *   2. pergunta ao Jev o estado da conversa;
 *   3. devolve close/wait/cancel, com motivo e probabilidades;
 *   4. grava cada decisão em ~/Library/Logs/RaviVoice/turn-end-provider.jsonl.
 *
 * Fail-safe: qualquer erro/timeout vira `wait` com `PROVIDER_ERROR`/`DEADLINE`.
 * O app nunca deve fechar por causa de uma falha deste processo.
 *
 * Rodar:  bun run turn-end/server.ts
 * Saúde:  GET http://127.0.0.1:8791/health
 */

import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const PORT = Number(process.env.JEV_TURN_END_PORT ?? 8791);
const HOST = "127.0.0.1";
const GATEWAY = "https://ai-gateway.vercel.sh/v4/ai/evaluation-model";
const MODEL = "typesafe-ai/jev";
const LOG = join(homedir(), "Library/Logs/RaviVoice/turn-end-provider.jsonl");
const STARTED = Date.now();

function readKey(): string {
  if (process.env.AI_GATEWAY_API_KEY) return process.env.AI_GATEWAY_API_KEY;
  const files = [
    join(homedir(), ".config/ravi-voice/jev.env"),
    join(homedir(), ".ravi/.env"),
  ];
  for (const file of files) {
    if (!existsSync(file)) continue;
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const m = /^\s*AI_GATEWAY_API_KEY\s*=\s*(.+?)\s*$/.exec(line);
      if (m) return m[1]!.replace(/^["']|["']$/g, "");
    }
  }
  return "";
}

const KEY = readKey();

const QUESTIONS = {
  estado_da_conversa: {
    type: "choice",
    instructions:
      "Classifique o estado da conversa DE VOZ imediatamente depois da última fala do agente. " +
      "O áudio do agente já terminou e está em silêncio. Escolha uma única opção.",
    criteria: {
      continua:
        "O agente fez uma pergunta direta, um convite para continuar, ou deixou uma pausa no meio de um assunto. " +
        "O usuário deve falar de novo para a conversa funcionar.",
      aguardando:
        "O agente prometeu voltar com uma resposta, ação ou confirmação (por exemplo: 'te aviso', 'vou pedir', " +
        "'já mandei', 'te conto quando responder'). O próximo evento esperado é do agente, não uma fala do usuário.",
      encerrada:
        "O agente se despediu, confirmou o encerramento, ou o usuário pediu para desligar e o agente concordou. " +
        "Nada mais é esperado nesta conversa.",
    },
  },
  fala_completa: {
    type: "boolean",
    instructions:
      "A última fala do agente termina uma ideia completa? Responda não se o texto foi cortado no meio de uma " +
      "frase, termina em reticências, ou é claramente um fragmento.",
  },
  pedido_de_encerramento: {
    type: "boolean",
    instructions:
      "O usuário pediu explicitamente para desligar, encerrar, fechar ou terminar a conversa AGORA? " +
      "Não conte pedidos hipotéticos ('se eu pedir para desligar'), pedidos de encerrar outra coisa, " +
      "nem despedidas casuais sem intenção de encerrar.",
  },
};

type Mode = "shadow" | "live" | "replay";

interface Signals {
  output_level: number;
  input_level: number;
  ms_since_agent_speech: number;
  ms_since_user_speech: number;
  eos: boolean;
  pending_work: boolean;
  close_requested: boolean;
}

interface Snippet {
  role: string;
  text: string;
}

interface RequestBody {
  schema?: string;
  request_id?: string;
  session_id?: string;
  turn_id?: string;
  candidate_id?: string;
  mode?: Mode;
  deadline_ms?: number;
  signals?: Signals;
  snippets?: {
    last_user?: string | null;
    last_agent?: string | null;
    recent?: Snippet[];
  };
  policy?: {
    min_state_prob?: number;
    min_complete_prob?: number;
    explicit_prob?: number;
    waiting_quiet_ms?: number;
  };
}

interface Decision {
  schema: "ravi.turn_end.decision/v1";
  request_id: string;
  decision: "close" | "wait" | "cancel";
  state: "continua" | "aguardando" | "encerrada" | null;
  state_prob: number | null;
  pode_prob: number | null;
  complete_prob: number | null;
  explicit_prob: number | null;
  confidence: number | null;
  reason_code: string;
  reason: string;
  provider: "jev";
  model: string;
  latency_ms: number;
  shadow: boolean;
  expires_in_ms: number;
  error?: string;
}

const cache = new Map<string, { at: number; decision: Decision }>();

function logLine(obj: any) {
  try {
    appendFileSync(LOG, JSON.stringify(obj) + "\n");
  } catch {
    // o log nunca pode derrubar o provedor
  }
}

function p(answer: any): number {
  return answer?.probability ?? 0;
}

function pc(answer: any, choice: string): number {
  return answer?.probabilities?.[choice] ?? 0;
}

function waitDecision(
  body: RequestBody,
  reasonCode: string,
  reason: string,
  started: number,
  extra: Partial<Decision> = {},
): Decision {
  return {
    schema: "ravi.turn_end.decision/v1",
    request_id: body.request_id ?? "?",
    decision: "wait",
    state: null,
    state_prob: null,
    pode_prob: null,
    complete_prob: null,
    explicit_prob: null,
    confidence: null,
    reason_code: reasonCode,
    reason,
    provider: "jev",
    model: MODEL,
    latency_ms: Date.now() - started,
    shadow: body.mode !== "live",
    expires_in_ms: 1500,
    ...extra,
  };
}

async function askJev(body: RequestBody, started: number): Promise<Decision> {
  const deadline = Math.max(250, Math.min(Number(body.deadline_ms ?? 800), 2000));
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), deadline);
  try {
    // Estado idêntico ao da PoC offline (bench.ts). Campos extras mudam a decisão:
    // no replay, `ultima_fala_do_usuario` + `trabalho_pendente` fizeram o c041 virar
    // "encerrada" (era "continua"). O D0 já cobre trabalho pendente.
    const state = {
      canal: "voz",
      conversa_recente: (body.snippets?.recent ?? []).slice(-4),
      ultima_fala_do_agente: body.snippets?.last_agent ?? "",
      agente_ainda_falando: false,
      silencio_desde_o_fim_da_fala_ms: body.signals?.ms_since_agent_speech ?? 0,
    };

    const res = await fetch(GATEWAY, {
      method: "POST",
      signal: controller.signal,
      headers: {
        Authorization: `Bearer ${KEY}`,
        "Content-Type": "application/json",
        "ai-gateway-protocol-version": "0.0.1",
        "ai-evaluation-model-specification-version": "4",
        "ai-model-id": MODEL,
      },
      body: JSON.stringify({ state, questions: QUESTIONS }),
    });

    if (!res.ok) {
      const text = await res.text();
      return waitDecision(body, "PROVIDER_ERROR", `gateway ${res.status}`, started, {
        error: text.slice(0, 200),
      });
    }

    const out: any = await res.json();
    const a = out.answers ?? {};
    const conf = out.providerMetadata?.typesafe?.confidence ?? {};
    const stateAnswer = a.estado_da_conversa ?? {};
    const choice = stateAnswer.choice as Decision["state"] | undefined;
    const stateProb = choice ? pc(stateAnswer, choice) : null;
    const podeProb =
      pc(stateAnswer, "encerrada") + pc(stateAnswer, "aguardando");
    const completa = p(a.fala_completa);
    const explicito = p(a.pedido_de_encerramento);

    const policy = body.policy ?? {};
    const minState = Number(policy.min_state_prob ?? 0.7);
    const minComplete = Number(policy.min_complete_prob ?? 0.5);
    const minExplicit = Number(policy.explicit_prob ?? 0.55);
    const waitingQuiet = Number(policy.waiting_quiet_ms ?? 3000);

    let decision: Decision["decision"] = "wait";
    let reasonCode = "STATE_CONTINUES";
    let reason = "conversa continua";

    if (choice && choice !== "continua" && explicito >= minExplicit && completa >= minComplete) {
      decision = "close";
      reasonCode = "EXPLICIT_CLOSE";
      reason = "pedido explícito + fala completa";
    } else if (choice === "encerrada" && podeProb >= minState && completa >= minComplete) {
      decision = "close";
      reasonCode = "STATE_ENDED";
      reason = "Jev: conversa encerrada + EOS";
    } else if (
      choice === "aguardando" &&
      podeProb >= minState &&
      completa >= minComplete &&
      (body.signals?.ms_since_agent_speech ?? 0) >= waitingQuiet
    ) {
      decision = "close";
      reasonCode = "WAITING_ASYNC";
      reason = "Jev: aguardando resposta assíncrona + silêncio";
    } else if (choice && choice !== "continua" && podeProb >= minState && completa < minComplete) {
      reasonCode = "INCOMPLETE_SPEECH";
      reason = "fala ainda não está completa";
    } else if (choice && choice !== "continua" && podeProb < minState) {
      reasonCode = "LOW_CONFIDENCE";
      reason = "Jev sem confiança para fechar";
    } else if (explicito >= minExplicit && choice === "continua") {
      reasonCode = "AGENT_NOT_CLOSING";
      reason = "pedido explícito, mas o agente ainda não fechou a fala";
    }

    return {
      schema: "ravi.turn_end.decision/v1",
      request_id: body.request_id ?? "?",
      decision,
      state: choice ?? null,
      state_prob: stateProb,
      pode_prob: podeProb,
      complete_prob: completa,
      explicit_prob: explicito,
      confidence: choice ? (conf.estado_da_conversa ?? null) : null,
      reason_code: reasonCode,
      reason,
      provider: "jev",
      model: MODEL,
      latency_ms: Date.now() - started,
      shadow: body.mode !== "live",
      expires_in_ms: 1500,
    };
  } catch (e: any) {
    const aborted = e?.name === "AbortError";
    return waitDecision(
      body,
      aborted ? "DEADLINE" : "PROVIDER_ERROR",
      aborted ? `sem resposta em ${deadline} ms` : String(e?.message ?? e).slice(0, 200),
      started,
    );
  } finally {
    clearTimeout(timeout);
  }
}

function validate(body: any): string | null {
  if (!body || typeof body !== "object") return "corpo inválido";
  if (body.schema && body.schema !== "ravi.turn_end.request/v1") return "schema inválido";
  if (!body.session_id) return "session_id obrigatório";
  if (!body.signals || typeof body.signals !== "object") return "signals obrigatório";
  if (typeof body.signals.eos !== "boolean") return "signals.eos obrigatório";
  if (!body.snippets || typeof body.snippets !== "object") return "snippets obrigatório";
  return null;
}

const server = Bun.serve({
  hostname: HOST,
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/health") {
      return Response.json({
        ok: true,
        provider: "jev",
        model: MODEL,
        version: "0.1.0",
        key: KEY ? "present" : "missing",
        uptime_s: Math.round((Date.now() - STARTED) / 1000),
        log: LOG,
      });
    }

    if (req.method === "POST" && url.pathname === "/v1/turn-end") {
      const started = Date.now();
      let body: RequestBody;
      try {
        body = (await req.json()) as RequestBody;
      } catch {
        return Response.json({ error: "JSON inválido" }, { status: 400 });
      }
      const invalid = validate(body);
      if (invalid) return Response.json({ error: invalid }, { status: 400 });

      const key = req.headers.get("idempotency-key") ?? `${body.session_id}/${body.candidate_id}`;
      const hit = cache.get(key);
      if (hit && Date.now() - hit.at < 2000) {
        return Response.json({ ...hit.decision, cached: true });
      }

      if (!KEY) {
        const d = waitDecision(body, "PROVIDER_ERROR", "AI_GATEWAY_API_KEY ausente", started);
        logLine({ type: "decision", ...d, mode: body.mode ?? "shadow" });
        return Response.json(d);
      }

      const decision = await askJev(body, started);
      cache.set(key, { at: Date.now(), decision });
      if (cache.size > 512) {
        for (const [k, v] of cache) if (Date.now() - v.at > 60_000) cache.delete(k);
      }
      logLine({
        type: "decision",
        ...decision,
        mode: body.mode ?? "shadow",
        signals: body.signals,
        candidate: body.candidate_id,
        session: body.session_id,
        last_user: body.snippets?.last_user?.slice(0, 200) ?? null,
        last_agent: body.snippets?.last_agent?.slice(0, 200) ?? null,
      });
      return Response.json(decision);
    }

    return Response.json({ error: "not found" }, { status: 404 });
  },
});

console.log(`[jev-turn-end] http://${HOST}:${PORT} | modelo ${MODEL} | log ${LOG}`);
console.log(`[jev-turn-end] chave do gateway: ${KEY ? "presente" : "AUSENTE"}`);
