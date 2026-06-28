#!/usr/bin/env bash
#
# install-service.sh
#
# Installs (or uninstalls) the always-on launchd service that keeps the Hermes
# gateway running on macOS — starting at login, restarting on crash, and
# re-applying the Catalina WhatsApp fix on every (re)start.
#
# It AUTO-DETECTS everything that previously had to be hand-edited into a plist:
#   - the node binary directory (and checks it's Node >= 20)
#   - the hermes binary directory (the bit that's easy to forget in PATH)
#   - your username and home directory
#   - the absolute path to this repo
# then generates the plist, creates ~/Library/LaunchAgents if needed, loads the
# service, and verifies it actually came up.
#
# Usage:
#   ./install-service.sh            # install (or reinstall) and start
#   ./install-service.sh --uninstall  # stop and remove the service
#   ./install-service.sh --print    # show the plist it WOULD write, don't install
#
set -euo pipefail

LABEL="com.hermes.gateway-catalina"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$REPO_DIR/hermes-gateway-catalina.sh"
OUT_LOG="/tmp/hermes-gateway-catalina.out.log"
ERR_LOG="/tmp/hermes-gateway-catalina.err.log"

log()  { printf '\033[0;36m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ok]\033[0m  %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- uninstall path ---------------------------------------------------------

if [ "${1:-}" = "--uninstall" ]; then
  if [ -f "$PLIST_DEST" ]; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    ok "Service stopped and removed ($PLIST_DEST deleted)."
  else
    warn "No service installed at $PLIST_DEST — nothing to do."
  fi
  log "Note: this does NOT touch your bridge, session, or Hermes data."
  exit 0
fi

# --- autodetection ----------------------------------------------------------

log "Detecting environment ..."

command -v node   >/dev/null 2>&1 || die "node not found on PATH. Install Node 20 (nvm install 20) and re-run."
command -v hermes >/dev/null 2>&1 || die "hermes not found on PATH. Is Hermes installed?"

NODE_BIN_DIR="$(cd "$(dirname "$(command -v node)")" && pwd)"
HERMES_BIN_DIR="$(cd "$(dirname "$(command -v hermes)")" && pwd)"
USER_NAME="$(id -un)"
USER_HOME="$HOME"

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 20 ] || die "Node >= 20 required for Baileys (found $(node --version)).
Run: nvm install 20 && nvm use 20   (and ideally: nvm alias default 20)"

[ -f "$WRAPPER" ]   || die "Wrapper not found at $WRAPPER (is the repo intact?)"
[ -x "$WRAPPER" ]   || { chmod +x "$WRAPPER"; log "Made wrapper executable."; }

# Build a PATH that includes BOTH the node dir and the hermes dir (the hermes
# dir, usually ~/.local/bin, is the one that's easy to miss — and breaks the
# service with 'hermes not found' if absent). De-dupe if they're the same.
if [ "$NODE_BIN_DIR" = "$HERMES_BIN_DIR" ]; then
  SERVICE_PATH="$NODE_BIN_DIR:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
else
  SERVICE_PATH="$HERMES_BIN_DIR:$NODE_BIN_DIR:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
fi

log "  node:    $NODE_BIN_DIR ($(node --version))"
log "  hermes:  $HERMES_BIN_DIR"
log "  user:    $USER_NAME"
log "  home:    $USER_HOME"
log "  wrapper: $WRAPPER"

# --- generate the plist -----------------------------------------------------

read -r -d '' PLIST <<EOF || true
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$WRAPPER</string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$SERVICE_PATH</string>
        <key>HOME</key>
        <string>$USER_HOME</string>
    </dict>

    <key>ThrottleInterval</key>
    <integer>30</integer>

    <key>StandardOutPath</key>
    <string>$OUT_LOG</string>
    <key>StandardErrorPath</key>
    <string>$ERR_LOG</string>
</dict>
</plist>
EOF

if [ "${1:-}" = "--print" ]; then
  printf '%s\n' "$PLIST"
  exit 0
fi

# --- install ----------------------------------------------------------------

mkdir -p "$HOME/Library/LaunchAgents"

# If a service is already loaded, unload it first so we cleanly replace it.
if [ -f "$PLIST_DEST" ]; then
  log "Existing service found — unloading before reinstall ..."
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

printf '%s\n' "$PLIST" > "$PLIST_DEST"
ok "Wrote $PLIST_DEST"

# Fresh logs so verification isn't confused by old runs.
rm -f "$OUT_LOG" "$ERR_LOG"

launchctl load "$PLIST_DEST"
launchctl start "$LABEL"
log "Service loaded and started. Waiting for it to come up ..."
sleep 8

# --- verify -----------------------------------------------------------------

status_line="$(launchctl list | grep "$LABEL" || true)"
pid="$(printf '%s' "$status_line" | awk '{print $1}')"

echo
if [ -n "$pid" ] && [ "$pid" != "-" ]; then
  ok "Service is RUNNING (pid $pid)."
  log "It will start at login and restart on crash."
else
  warn "Service is not showing a live PID yet. Last status: ${status_line:-<none>}"
  warn "Check the error log below."
fi

echo
log "---- $OUT_LOG (tail) ----"
tail -n 15 "$OUT_LOG" 2>/dev/null || echo "(empty)"
echo
log "---- $ERR_LOG (tail) ----"
tail -n 15 "$ERR_LOG" 2>/dev/null || echo "(empty)"

echo
cat <<NEXT
Done. Useful commands:
  Status:     launchctl list | grep $LABEL      (a number = running)
  Logs:       cat $OUT_LOG
  Stop/remove:./install-service.sh --uninstall
  Reinstall:  ./install-service.sh

If WhatsApp isn't paired yet, pair once with:  hermes whatsapp
Then message yourself on WhatsApp — the agent replies.

IMPORTANT: with this service running, do NOT also run 'hermes gateway' by hand
or a Docker gateway with WhatsApp enabled. Two gateways corrupt the session.
NEXT
