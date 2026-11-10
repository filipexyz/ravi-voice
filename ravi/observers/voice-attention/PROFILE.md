---
id: voice-attention
version: "2"
label: voice-attention
description: Silence-first attention with conservative abandoned-topic detection; relevance, privacy and dedupe.
defaults:
  eventTypes:
    - message.user
    - message.assistant
    - turn.complete
    - turn.failed
    - turn.interrupt
  deliveryPolicy: end_of_turn
  mode: report
templates:
  delivery:
    realtime: ./delivery/realtime.md
    debounce: ./delivery/debounce.md
    end_of_turn: ./delivery/end-of-turn.md
  events:
    default: ./events/default.md
    message.user: ./events/message-user.md
    message.assistant: ./events/message-assistant.md
    turn.complete: ./events/turn-complete.md
    turn.failed: ./events/turn-failed.md
    turn.interrupt: ./events/turn-interrupt.md
rendererHints:
  label: Default observer
---

# Voice Attention

Decision contract is embedded in delivery templates. AGENTS.md privacy and silence-first rules remain in force. Requires the protected observer-announcement consumer before activation. No time quotas.
