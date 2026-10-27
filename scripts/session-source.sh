#!/usr/bin/env bash
# Installs exactly one session source and removes the other, so two writers never report the same sessions.
# Usage: session-source.sh [herdr|claude]. Without an argument it keeps the one already installed, and asks when
# neither or both are.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE="$HOME/.local/state/stemmix"
PLUGIN=stemmix@sound-mod
MARKETPLACE=sound-mod

has_herdr() { command -v herdr >/dev/null; }
has_claude() { command -v claude >/dev/null; }
herdr_installed() { has_herdr && herdr plugin list 2>/dev/null | grep -q '^- stemmix '; }
claude_installed() { has_claude && claude plugin list 2>/dev/null | grep -qF "$PLUGIN"; }

source=${1:-}
if [ -z "$source" ]; then
  if herdr_installed && ! claude_installed; then
    source=herdr
  elif claude_installed && ! herdr_installed; then
    source=claude
  elif [ -t 0 ]; then
    read -r -p "Session source, herdr or claude: " source
  else
    echo "session source: pass herdr or claude (./install.sh herdr)" >&2
    exit 1
  fi
fi

remove_claude() {
  if claude_installed; then claude plugin uninstall "$PLUGIN" >/dev/null; fi
  if has_claude && claude plugin marketplace list 2>/dev/null | grep -q "❯ $MARKETPLACE\$"; then
    claude plugin marketplace remove "$MARKETPLACE" >/dev/null
  fi
}

remove_herdr() {
  if herdr_installed; then herdr plugin unlink stemmix >/dev/null; fi
  # The bridge outlives its plugin entry; SIGTERM makes it remove its session files and exit.
  if [ -f "$STATE/herdr-bridge.pid" ]; then
    kill "$(cat "$STATE/herdr-bridge.pid")" 2>/dev/null || true
    rm -f "$STATE/herdr-bridge.pid"
  fi
}

case "$source" in
  herdr)
    has_herdr || { echo "session source: herdr is not on PATH" >&2; exit 1; }
    remove_claude
    herdr_installed || herdr plugin link "$PWD/herdr-plugin" >/dev/null
    herdr plugin action invoke restart --plugin stemmix >/dev/null
    echo "session source: herdr (the Claude Code plugin is removed; run /reload-plugins in open Claude sessions)"
    ;;
  claude)
    has_claude || { echo "session source: claude is not on PATH" >&2; exit 1; }
    remove_herdr
    claude plugin marketplace list 2>/dev/null | grep -q "❯ $MARKETPLACE\$" || claude plugin marketplace add "$PWD" >/dev/null
    claude_installed || claude plugin install "$PLUGIN" >/dev/null
    echo "session source: claude (the herdr plugin is removed; run /reload-plugins in open Claude sessions)"
    ;;
  *)
    echo "session source: '$source' is not herdr or claude" >&2
    exit 1
    ;;
esac
