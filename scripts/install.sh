#!/usr/bin/env bash
# Installs Ravi Voice into ~/Applications and keeps it alive with a per-user LaunchAgent
# (starts at login, restarts if it crashes). `scripts/install.sh uninstall` removes it.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="bot.ravi.voice"
DEST="$HOME/Applications/RaviVoice.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -f "$DEST/Contents/MacOS/RaviVoice" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$DEST"
  echo "removed $LABEL"
  exit 0
fi

stop_agent() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  # bootout is asynchronous; bootstrapping before the old job is gone fails with error 5.
  for _ in $(seq 50); do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
  done
  # Copies started outside launchd (e.g. macOS "Quit & Reopen") would keep running old code.
  pkill -f "$DEST/Contents/MacOS/RaviVoice" 2>/dev/null || true
}

scripts/build-app.sh
stop_agent
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/RaviVoice"
rm -rf "$DEST"
# Move, don't copy: a second bundle with the same id shows up twice in Spotlight/Launchpad.
mv build/RaviVoice.app "$DEST"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/RaviVoice</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/RaviVoice/stdout.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/RaviVoice/stderr.log</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $DEST and started $LABEL"
