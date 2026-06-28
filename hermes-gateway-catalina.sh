#!/usr/bin/env bash
#
# hermes-gateway-catalina.sh
#
# OPTIONAL convenience wrapper. Use this INSTEAD of launching `hermes gateway`
# directly (or instead of the launchd service that `hermes gateway install`
# registers) if you want the Catalina WhatsApp fix to be re-applied
# automatically on every start.
#
# Why this exists:
#   A `hermes update` rewrites the WhatsApp bridge's package.json back to the
#   GitHub-ref Baileys dependency, which re-breaks the install on Catalina.
#   This wrapper runs fix-whatsapp-catalina.sh (idempotent — a no-op when the
#   bridge is already healthy) BEFORE starting the gateway, so the bridge is
#   always patched before Hermes tries to use it.
#
#   The Python gateway adapter (gateway/platforms/whatsapp.py) is what actually
#   spawns bridge.js, so this wrapper does NOT launch the bridge itself — it
#   only guarantees the bridge is patched, then hands off to `hermes gateway`.
#
# Usage:
#   ./hermes-gateway-catalina.sh                 # fix, then run gateway (foreground)
#   ./hermes-gateway-catalina.sh -- --some-flag  # anything after `--` is passed
#                                                # straight through to `hermes gateway`
#
# For always-on / auto-restart / start-at-boot, register THIS script with
# launchd instead of using `hermes gateway install`. See the README and the
# com.hermes.gateway-catalina.plist.example in this repo.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/fix-whatsapp-catalina.sh"

log() { printf '\033[0;36m[wrapper]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[wrapper:error]\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$FIX_SCRIPT" ] || die "Cannot find/execute $FIX_SCRIPT
Make sure fix-whatsapp-catalina.sh is next to this wrapper and is chmod +x."

command -v hermes >/dev/null 2>&1 || die "hermes not found on PATH."

# Split args: everything after a literal `--` goes to `hermes gateway`.
gateway_args=()
seen_sep=0
for a in "$@"; do
  if [ "$seen_sep" -eq 1 ]; then
    gateway_args+=("$a")
  elif [ "$a" = "--" ]; then
    seen_sep=1
  fi
done

log "Ensuring the WhatsApp bridge is patched for Catalina (idempotent) ..."
"$FIX_SCRIPT"

log "Starting hermes gateway ..."
# Note: "${gateway_args[@]}" on an empty array trips `set -u` in the bash 3.2
# that ships with macOS, so expand it only when it actually has elements.
if [ "${#gateway_args[@]}" -gt 0 ]; then
  exec hermes gateway "${gateway_args[@]}"
else
  exec hermes gateway
fi
