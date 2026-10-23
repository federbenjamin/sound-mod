#!/usr/bin/env bash
# Builds and signs the stemmix daemon, installs it as a launchd user agent, and checks the plugin is registered.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.benjaminfeder.stemmix
APP="$HOME/Applications/Stemmix.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.local/state/stemmix"

swift build -c release --package-path daemon >/dev/null
mkdir -p "$APP/Contents/MacOS" "$STATE/sessions" "$HOME/Library/LaunchAgents"
cp daemon/.build/release/stemmix "$APP/Contents/MacOS/stemmix"
cp daemon/Info.plist "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "signed: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "signed ad hoc: no Apple Development identity in the keychain, so the audio permission is asked again after every rebuild"
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/stemmix</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$STATE/daemon.out.log</string>
  <key>StandardErrorPath</key><string>$STATE/daemon.err.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "daemon: running as $LABEL (log: $STATE/stemmix.log)"

if grep -q '"stemmix@sound-mod": true' "$HOME/.claude/settings.json" 2>/dev/null; then
  echo "plugin: registered; run /reload-plugins in open sessions"
else
  cat <<EOF
plugin: not registered. In ~/.claude/settings.json add
  extraKnownMarketplaces.sound-mod = { "source": { "source": "directory", "path": "$PWD" } }
  enabledPlugins["stemmix@sound-mod"] = true
then run /reload-plugins.
EOF
fi
echo "first run: when a session works while music plays, macOS asks once to allow Stemmix 'System Audio Recording'. Click Allow."
