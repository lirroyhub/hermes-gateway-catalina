#!/usr/bin/env bash
#
# fix-whatsapp-catalina.sh
#
# Makes the Hermes Agent WhatsApp bridge install and run on macOS 10.15
# Catalina (and other "too old for modern prebuilt binaries" machines).
#
# ---------------------------------------------------------------------------
# THE PROBLEM
# ---------------------------------------------------------------------------
# Hermes pins its WhatsApp bridge dependency on Baileys to a *GitHub commit*:
#
#   "@whiskeysockets/baileys": "WhiskeySockets/Baileys#<commit>"
#
# Installing a dependency from a GitHub ref makes npm run that package's
# `prepare` script, which compiles Baileys' TypeScript. That compile step
# pulls in `esbuild`. esbuild ships a Go-based native binary built for
# macOS 12.0+, and on Catalina it crashes during its own postinstall version
# check with:
#
#   dyld: Symbol not found: _SecTrustCopyCertificateChain
#   (which was built for Mac OS X 12.0)
#
# So `npm install` for the bridge dies and WhatsApp never connects.
#
# ---------------------------------------------------------------------------
# THE FIX
# ---------------------------------------------------------------------------
# Install Baileys from the *npm registry* instead of from GitHub. The npm
# release is already compiled to JavaScript, so there is no `prepare` step,
# no TypeScript build, and esbuild is never invoked. Nothing to crash.
#
# Bonus: the commit Hermes pins resolves to 7.0.0-rc.9, which npm flags for a
# known message-spoofing zero-day (advisory GHSA-qvv5-jq5g-4cgg). Pinning a
# fixed npm release (>= 7.0.0-rc12) is therefore also *more secure* than the
# default Hermes install.
#
# Two extra things this script handles, learned the hard way:
#
#   1. THERE ARE TWO COPIES OF THE BRIDGE.
#        ~/.hermes/scripts/whatsapp-bridge              (a copy)
#        ~/.hermes/hermes-agent/scripts/whatsapp-bridge (the one the GATEWAY
#                                                        actually runs)
#      Patching only the first one looks like it works (a manual `node
#      bridge.js` connects) but the gateway keeps failing because it uses the
#      second. This script patches EVERY copy it finds.
#
#   2. link-preview-js IS A MISSING OPTIONAL DEP.
#      Baileys lazily imports `link-preview-js`; the npm install doesn't pull
#      it in, and the bridge errors with ERR_MODULE_NOT_FOUND at runtime. We
#      install it explicitly.
#
# This script is idempotent: run it as many times as you like. If a copy is
# already on the npm version it's left alone. After a `hermes update` reverts
# package.json back to the GitHub ref, just run it again.
#
# ---------------------------------------------------------------------------
# MAINTENANCE NOTE
# ---------------------------------------------------------------------------
# BAILEYS_VERSION below was validated against the bridge.js that Hermes ships
# as of mid-2026. If a future Hermes update bumps the bridge to a Baileys
# version whose API differs, bump this to the matching npm release. Check the
# newest with:  npm view @whiskeysockets/baileys version
#
set -euo pipefail

# --- configuration ---------------------------------------------------------

# The npm version of Baileys to pin. See MAINTENANCE NOTE above.
BAILEYS_VERSION="7.0.0-rc13"

# Hermes home. Override with HERMES_HOME if your install differs.
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

# All known bridge locations. The SECOND is the one the gateway actually runs;
# the first is a copy that exists on many installs. We patch whichever exist.
BRIDGE_DIRS=(
  "$HERMES_HOME/hermes-agent/scripts/whatsapp-bridge"
  "$HERMES_HOME/scripts/whatsapp-bridge"
)

# --- helpers ---------------------------------------------------------------

log()  { printf '\033[0;36m[fix]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[ok]\033[0m  %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight --------------------------------------------------------------

command -v node >/dev/null 2>&1 || die "node not found on PATH."
command -v npm  >/dev/null 2>&1 || die "npm not found on PATH."

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  die "Baileys $BAILEYS_VERSION needs Node >= 20 (you have $(node --version)).
On Catalina, install it with:  nvm install 20 && nvm use 20
(The official 'unsupported' label is conservative -- the v20 darwin-x64 build
does run on Catalina.) Tip: 'nvm alias default 20' so the gateway inherits it."
fi

is_github_ref() {
  case "$1" in
    *WhiskeySockets/Baileys*|github:*|*"#"*) return 0 ;;
    *) return 1 ;;
  esac
}

read_baileys() {
  node -e '
    const fs = require("fs");
    try {
      const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write((p.dependencies && p.dependencies["@whiskeysockets/baileys"]) || "");
    } catch (e) { process.stdout.write(""); }
  ' "$1"
}

# Patch a single bridge directory. Returns 0 if it did work, 1 if skipped.
patch_bridge() {
  local dir="$1"
  local pkg="$dir/package.json"

  [ -f "$pkg" ] || { warn "No package.json in $dir -- skipping."; return 1; }

  local current
  current="$(read_baileys "$pkg")"
  [ -n "$current" ] || { warn "Couldn't read Baileys dep in $pkg -- skipping."; return 1; }

  # Decide if a clean (re)install is needed. We reinstall when EITHER the dep
  # still points at GitHub, OR baileys isn't actually importable from this dir
  # (a half-built install from a previously-failed GitHub compile).
  local needs_fix=0
  if is_github_ref "$current"; then
    log "[$dir]"
    log "  Baileys points at GitHub ($current) -- will repoint to npm $BAILEYS_VERSION."
    needs_fix=1
  elif [ ! -f "$dir/node_modules/@whiskeysockets/baileys/lib/index.js" ] \
    && [ ! -f "$dir/node_modules/@whiskeysockets/baileys/index.js" ]; then
    log "[$dir]"
    log "  Baileys dep is '$current' but the package isn't fully installed -- will reinstall."
    needs_fix=1
  fi

  # Also ensure link-preview-js is present even when baileys looks fine.
  local needs_lp=0
  if [ ! -d "$dir/node_modules/link-preview-js" ]; then
    needs_lp=1
  fi

  if [ "$needs_fix" -eq 0 ] && [ "$needs_lp" -eq 0 ]; then
    ok "[$dir] already healthy (Baileys=$current, link-preview-js present). Skipping."
    return 1
  fi

  cd "$dir"

  # Back up package.json: a stable pristine copy once, plus a timestamped one.
  if [ ! -f "package.json.hermes-original" ]; then
    cp package.json package.json.hermes-original
    log "  Saved pristine original to package.json.hermes-original"
  fi
  cp package.json "package.json.bak.$(date +%Y%m%d-%H%M%S)"

  if [ "$needs_fix" -eq 1 ]; then
    node -e '
      const fs = require("fs");
      const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      p.dependencies["@whiskeysockets/baileys"] = process.argv[2];
      fs.writeFileSync(process.argv[1], JSON.stringify(p, null, 2) + "\n");
    ' "$pkg" "$BAILEYS_VERSION"
    ok "  package.json pins @whiskeysockets/baileys = $BAILEYS_VERSION"

    log "  Clean install (removing node_modules + package-lock.json)..."
    rm -rf node_modules package-lock.json
    npm install
  fi

  # link-preview-js: Baileys' lazy optional dep. Install if missing.
  if [ ! -d "$dir/node_modules/link-preview-js" ]; then
    log "  Installing missing optional dep: link-preview-js"
    npm install link-preview-js
  fi

  log "  Verifying Baileys imports cleanly..."
  node -e 'import("@whiskeysockets/baileys").then(()=>console.log("  import OK")).catch(e=>{console.error(e);process.exit(1)})'

  ok "[$dir] patched."
  return 0
}

# --- main -------------------------------------------------------------------

found_any=0
patched_any=0

for dir in "${BRIDGE_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    found_any=1
    if patch_bridge "$dir"; then
      patched_any=1
    fi
  fi
done

if [ "$found_any" -eq 0 ]; then
  die "No WhatsApp bridge found under $HERMES_HOME.
Looked in:
  ${BRIDGE_DIRS[*]}
Is Hermes installed and has WhatsApp been enabled at least once?
(Enabling WhatsApp once creates the bridge directory, even if it fails to
install on Catalina.)"
fi

echo
if [ "$patched_any" -eq 1 ]; then
  ok "WhatsApp bridge patched for Catalina."
  log "Baileys: $BAILEYS_VERSION (npm, prebuilt -- no esbuild, no dyld crash)"
else
  ok "All bridge copies already healthy. Nothing to do."
fi

cat <<'NEXT'

Next steps:
  1. Pair (only needed the first time, or after clearing the session):
       hermes whatsapp        # scan the QR with WhatsApp > Linked Devices
     NOTE: pair with `hermes whatsapp`, NOT a manual `node bridge.js`. The
     gateway looks for the session in its own path; pairing the manual way
     puts creds in the wrong place and the gateway won't find them.
  2. Start the gateway:
       hermes gateway
  3. Message yourself on WhatsApp -- the agent replies (prefixed "Hermes Agent").

Run only ONE gateway at a time (no parallel Docker gateway with WhatsApp
enabled). Two gateways sharing ~/.hermes corrupt the WhatsApp session.
NEXT
