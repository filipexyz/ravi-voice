/**
 * report.ts — resumo do modo sombra do fim de turno.
 *
 * Lê ~/Library/Logs/RaviVoice/turn-end.jsonl (eventos do app) e
 * ~/.config/ravi-voice/turn-end-shadow.json (janela de 72h).
 *
 * Não age em nada. Só mede:
 *   - candidatos D0 observados;
 *   - o que o Jev respondeu (close/wait/cancel) e o que o app teria feito;
 *   - quantas falas do usuário vieram depois de cada candidato;
 *   - quantos seriam cortes se o app tivesse fechado (D0 sozinho × D0+Jev).
 *
 * Uso: bun run turn-end/report.ts [--json]
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LIVE = join(homedir(), "Library/Logs/RaviVoice/turn-end.jsonl");
const WINDOW = join(homedir(), ".config/ravi-voice/turn-end-shadow.json");
const JSON_OUT = process.argv.includes("--json");

type Event = any;

function readLines(path: string): Event[] {
  if (!existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function pct(n: number, d: number) {
  return d ? Math.round((n / d) * 1000) / 10 : 0;
}

function percentile(values: number[], q: number) {
  if (!values.length) return null;
  const s = [...values].sort((a, b) => a - b);
  return s[Math.floor(q * (s.length - 1))];
}

function main() {
  const events = readLines(LIVE);
  const window = existsSync(WINDOW) ? JSON.parse(readFileSync(WINDOW, "utf8")) : null;
  const candidates = events.filter((e) => e.type === "candidate");
  const userSpeech = events.filter((e) => e.type === "user_speech");
  const sessions = events.filter((e) => e.type === "session_end");

  const bySession = new Map<string, Event[]>();
  for (const s of userSpeech) {
    if (!s.session) continue;
    const list = bySession.get(s.session) ?? [];
    list.push(s);
    bySession.set(s.session, list);
  }

  function nextUserSpeech(c: Event): number | null {
    const list = bySession.get(c.session) ?? [];
    const at = Date.parse(c.at);
    let best: number | null = null;
    for (const s of list) {
      const t = Date.parse(s.at);
      if (!Number.isFinite(t) || t < at) continue;
      const delta = t - at;
      if (best === null || delta < best) best = delta;
    }
    return best;
  }

  const enriched = candidates.map((c) => {
    const next = nextUserSpeech(c);
    const appClose = c.app_decision === "close";
    const jevClose = c.decision === "close";
    return {
      candidate: c.candidate,
      session: c.session,
      at: c.at,
      mode: c.mode ?? "shadow",
      state: c.state,
      decision: c.decision,
      app_decision: c.app_decision,
      acted: c.acted === true,
      latency_ms: c.latency_ms,
      reason_code: c.reason_code,
      next_user_speech_ms: next,
      // D0 sozinho fecharia em todo candidato; 2 s depois do candidato.
      d0_would_cut: next !== null && next < 2000,
      jev_would_cut: appClose && next !== null && next < 2000,
      jev_would_cut_3s: appClose && next !== null && next < 3000,
    };
  });

  const acted = enriched.filter((c) => c.acted).length;
  const shadow = enriched.filter((c) => c.mode === "shadow");
  const live = enriched.filter((c) => c.mode === "live");
  const shadowActed = shadow.filter((c) => c.acted);
  const liveActed = live.filter((c) => c.acted);
  const withNext = enriched.filter((c) => c.next_user_speech_ms !== null);
  const jevClose = enriched.filter((c) => c.app_decision === "close");
  const d0Cuts = enriched.filter((c) => c.d0_would_cut);
  const jevCuts = enriched.filter((c) => c.jev_would_cut);
  const jevCuts3 = enriched.filter((c) => c.jev_would_cut_3s);

  const byState = enriched.reduce<Record<string, number>>((acc, c) => {
    const k = c.state ?? "sem_estado";
    acc[k] = (acc[k] ?? 0) + 1;
    return acc;
  }, {});
  const byReason = enriched.reduce<Record<string, number>>((acc, c) => {
    const k = c.reason_code ?? "sem_reason";
    acc[k] = (acc[k] ?? 0) + 1;
    return acc;
  }, {});

  const report = {
    generated_at: new Date().toISOString(),
    window,
    events: {
      candidates: candidates.length,
      user_speech: userSpeech.length,
      sessions_ended: sessions.length,
    },
    acted,
    by_mode: { shadow: shadow.length, live: live.length },
    by_state: byState,
    by_reason: byReason,
    latency_ms: {
      p50: percentile(enriched.map((c) => c.latency_ms).filter((n) => typeof n === "number"), 0.5),
      p95: percentile(enriched.map((c) => c.latency_ms).filter((n) => typeof n === "number"), 0.95),
    },
    comparison: {
      candidates: enriched.length,
      candidates_with_next_user_speech: withNext.length,
      d0_alone_would_cut: d0Cuts.length,
      d0_alone_cut_rate_pct: pct(d0Cuts.length, enriched.length),
      jev_would_close: jevClose.length,
      jev_would_cut_2s: jevCuts.length,
      jev_would_cut_3s: jevCuts3.length,
      jev_cut_rate_2s_pct: pct(jevCuts.length, enriched.length),
    },
    safety: {
      shadow_never_acted: shadowActed.length === 0,
      live_closes: liveActed.length,
      note: shadowActed.length > 0
        ? "ATENÇÃO: houve acted=true em modo shadow; isso não deveria acontecer."
        : liveActed.length > 0
          ? `Live ativo: ${liveActed.length} fechamento(s) causado(s) pelo Jev.`
          : "Nenhum fechamento foi causado pelo caminho Jev.",
    },
    examples: enriched.slice(-12),
  };

  if (JSON_OUT) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  const w = report.window;
  console.log("FIM DE TURNO — RELATÓRIO DE SOMBRA");
  console.log(w ? `janela: ${w.startedAt} → ${w.endsAt} (active=${w.active})` : "janela: não encontrada");
  console.log(`candidatos: ${report.events.candidates} · falas do usuário: ${report.events.user_speech} · sessões: ${report.events.sessions_ended}`);
  console.log(`fechamentos causados pelo Jev: ${acted} (live: ${liveActed.length})`);
  console.log(`modos: ${JSON.stringify(report.by_mode)}`);
  console.log(`estados: ${JSON.stringify(byState)}`);
  console.log(`motivos: ${JSON.stringify(byReason)}`);
  console.log(`latência: p50=${report.latency_ms.p50} ms · p95=${report.latency_ms.p95} ms`);
  console.log("");
  console.log("COMPARAÇÃO");
  console.log(`D0 sozinho: ${d0Cuts.length}/${enriched.length} cortes (${report.comparison.d0_alone_cut_rate_pct}%)`);
  console.log(`D0 + Jev: ${jevCuts.length}/${enriched.length} cortes em 2 s (${report.comparison.jev_cut_rate_2s_pct}%); ${jevCuts3.length} em 3 s`);
  console.log(`Jev fecharia: ${jevClose.length}/${enriched.length}`);
  console.log("");
  console.log(report.safety.note);
}

main();
