#!/usr/bin/env bash
# Wires Ravi Voice into Ravi:
#   - app `voice` (~/.ravi/apps/voice): agents run `ravi voice say --text "..."` → ravi.voice.message
#   - shell trigger on ravi.voice.> → `RaviVoice deliver` → the Mac app's inbox → spoken
# Idempotent. `scripts/ravi-setup.sh remove` undoes it.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$HOME/Applications/RaviVoice.app/Contents/MacOS/RaviVoice"
APP_DIR="$HOME/.ravi/apps/voice"
TRIGGER="ravi-voice-inbox"

# The text listing, not --json: piped JSON from `ravi triggers list` gets cut at 64 KB.
trigger_id() {
  ravi triggers list 2>/dev/null | awk -v name="$TRIGGER" '$2 == name { print $1; exit }'
}

if [[ "${1:-}" == "remove" ]]; then
  id="$(trigger_id)"; [[ -n "$id" ]] && ravi triggers rm "$id" --execute >/dev/null && echo "trigger removed"
  rm -rf "$APP_DIR" && echo "app removed"
  exit 0
fi

mkdir -p "$APP_DIR"
sed "s#__RAVI_VOICE_BIN__#$BIN#g" ravi/ravi.app.json > "$APP_DIR/ravi.app.json"
ravi apps check voice --json | python3 -c "import json,sys; d=json.load(sys.stdin); r=(d.get('results') or [d])[0]; print('app voice:', 'ok' if r.get('ok') else r.get('errors'))"

if [[ -z "$(trigger_id)" ]]; then
  ravi triggers add "$TRIGGER" \
    --topic 'ravi.voice.>' \
    --shell "$BIN deliver" \
    --timeout 30s \
    --json >/dev/null
  echo "trigger $TRIGGER created"
else
  echo "trigger $TRIGGER already exists"
fi
# Triggers default to a 5s cooldown, which drops back-to-back messages. Ravi builds with
# optional cooldown accept `off`; older ones have a 1s minimum (RaviVoice say spaces
# publishes by 1.2s to stay clear of it).
id="$(trigger_id)"
if ravi triggers set "$id" cooldown off --json >/dev/null 2>&1; then
  echo "trigger cooldown: off"
else
  ravi triggers set "$id" cooldown 1s --json >/dev/null
  echo "trigger cooldown: 1s (this Ravi has no 'off' yet)"
fi
