# Hermes Agent — WhatsApp on macOS Catalina (10.15)

Make the [Hermes Agent](https://github.com/NousResearch/hermes-agent) WhatsApp
bridge **install and run natively on macOS 10.15 Catalina** — no Docker, no VM.

An idempotent fix script repoints the bridge's Baileys dependency from a GitHub
build (which fails on Catalina) to the equivalent prebuilt npm release (which
doesn't). An optional auto-detecting installer sets up a launchd service so the
gateway starts at boot, restarts on crash, and re-applies the fix across Hermes
updates — no plist hand-editing.

> **TL;DR**
> ```bash
> nvm install 20 && nvm use 20        # Baileys 7 needs Node >= 20
> ./fix-whatsapp-catalina.sh          # patch the bridge (safe to re-run anytime)
> hermes gateway                       # WhatsApp now connects
> ```

---

## Who this is for

You're running Hermes natively on an Intel Mac stuck on **macOS 10.15 Catalina**
(or another macOS old enough that modern prebuilt native binaries refuse to
run), Telegram works fine, but enabling WhatsApp dies with:

```
[Whatsapp] Installing WhatsApp bridge dependencies...
[Whatsapp] npm install failed:
```

…and a manual `npm install` in the bridge directory reveals the real cause:

```
dyld: Symbol not found: _SecTrustCopyCertificateChain
  Referenced from: .../node_modules/esbuild/bin/esbuild (which was built for Mac OS X 12.0)
  Expected in: /System/Library/Frameworks/Security.framework/Versions/A/Security
```

---

## The root cause (three layers)

It took peeling back three layers to find the real problem. None of them is
"Catalina can't do WhatsApp" — they're all mundane and fixable.

**Layer 1 — Node version.** Hermes' bridge uses Baileys 7, which requires
Node ≥ 20. Catalina's last *officially* supported Node is 18. But the Node 20
`darwin-x64` build **does run on Catalina** despite the conservative "unsupported"
label — install it with `nvm install 20`. (Node itself is not the wall.)

**Layer 2 — esbuild (the actual wall).** Hermes pins Baileys to a *GitHub
commit*:

```json
"@whiskeysockets/baileys": "WhiskeySockets/Baileys#<commit>"
```

Installing from a GitHub ref makes npm run Baileys' `prepare` script, which
**compiles its TypeScript**, which pulls in **esbuild**. esbuild ships a
Go-based native binary built for **macOS 12.0+**; on Catalina it crashes in its
own postinstall version check (`esbuild --version`) with the
`_SecTrustCopyCertificateChain` dyld error above. That kills the whole install.

**Layer 3 — a security bonus.** The pinned commit resolves to Baileys
`7.0.0-rc.9`, which npm flags for a known **message-spoofing zero-day**
([GHSA-qvv5-jq5g-4cgg](https://github.com/WhiskeySockets/Baileys/security/advisories/GHSA-qvv5-jq5g-4cgg)).
Any fix that moves to `>= 7.0.0-rc12` is therefore also *more secure* than the
stock Hermes install.

### Two more gotchas (the ones that waste an afternoon)

**There are TWO copies of the bridge.** Hermes ships the WhatsApp bridge in
*two* places:

```
~/.hermes/scripts/whatsapp-bridge              # a copy
~/.hermes/hermes-agent/scripts/whatsapp-bridge # the one the GATEWAY runs
```

Patch only the first and everything *looks* fixed — a manual `node bridge.js`
connects fine — but `hermes gateway` keeps failing, because the gateway runs
the **second** copy, which is still broken. This script patches every copy it
finds.

**`link-preview-js` is a missing optional dependency.** Baileys lazily imports
`link-preview-js`; the npm install doesn't pull it in, so the bridge throws
`ERR_MODULE_NOT_FOUND` at runtime. The script installs it explicitly.

**Pair with `hermes whatsapp`, not `node bridge.js`.** The gateway looks for the
WhatsApp session in its own path. If you pair by running the bridge manually,
the credentials land somewhere the gateway won't look, and it reports
"enabled but not paired." Always pair with `hermes whatsapp`.

## The fix

**Install Baileys from the npm registry instead of from GitHub.** The npm
release is already compiled to JavaScript — there is no `prepare` step, no
TypeScript build, and **esbuild is never invoked**, so there's nothing to crash.
Pin a version `>= 7.0.0-rc12` and you dodge the zero-day too.

That's the whole trick. This repo just makes it robust and repeatable, because
a `hermes update` reverts `package.json` back to the GitHub ref and re-breaks
things.

---

## What's in this repo

| File | What it does |
|------|--------------|
| `fix-whatsapp-catalina.sh` | **The fix.** Idempotent. Finds every bridge copy (both `scripts/` and `hermes-agent/scripts/`), and for each one that points at GitHub (broken on Catalina) or is half-installed, repoints Baileys to a prebuilt npm release, reinstalls cleanly, and adds the missing `link-preview-js` dep. A no-op on copies that are already healthy. |
| `hermes-gateway-catalina.sh` | **Optional wrapper.** Runs the fix (no-op when healthy), then `exec hermes gateway`. Use it instead of launching the gateway directly so the fix is re-applied after every update. |
| `install-service.sh` | **Optional always-on installer.** Auto-detects node, hermes, your user/home, and the repo path; generates the launchd plist; creates `~/Library/LaunchAgents`; loads and verifies the service. No hand-editing. `--uninstall` to remove, `--print` to preview the plist. |
| `com.hermes.gateway-catalina.plist.example` | Reference plist, in case you want to inspect or write it by hand instead of using the installer. |

---

## Requirements

- macOS 10.15 Catalina (or similar), Intel.
- Hermes installed natively, with the WhatsApp bridge present at
  `~/.hermes/scripts/whatsapp-bridge` (Hermes creates it the first time you
  enable WhatsApp).
- **Node ≥ 20**, via [nvm](https://github.com/nvm-sh/nvm):
  ```bash
  nvm install 20
  nvm use 20
  nvm alias default 20      # optional: make 20 your default
  ```

---

## Usage

### 1. One-time / after-an-update fix

```bash
git clone https://github.com/lirroyhub/hermes-gateway-catalina.git
cd hermes-gateway-catalina
chmod +x fix-whatsapp-catalina.sh

./fix-whatsapp-catalina.sh
```

The script will:
1. Verify Node ≥ 20.
2. Find every bridge copy (`scripts/` and `hermes-agent/scripts/`).
3. For each copy that points at GitHub or is half-installed: back it up,
   repoint Baileys to the npm release, `rm -rf node_modules package-lock.json`,
   `npm install` (no esbuild), and install the missing `link-preview-js`.
4. Verify Baileys imports cleanly. Healthy copies are left untouched.

Re-run it any time. If the bridge is already on the npm version it prints
`Nothing to do` and exits. After a `hermes update` re-breaks the bridge, just
run it again.

Then start Hermes as usual:

```bash
hermes gateway
```

You should see:

```
🌉 WhatsApp bridge listening on port 3000
✅ WhatsApp connected!
```

### 2. Optional — auto-apply on every start

Instead of `hermes gateway`, run the wrapper:

```bash
chmod +x hermes-gateway-catalina.sh
./hermes-gateway-catalina.sh
```

It applies the fix (a no-op when healthy) and then hands off to
`hermes gateway`. Pass-through flags after `--`:

```bash
./hermes-gateway-catalina.sh -- --verbose
```

### 3. Optional — always-on (start at boot, auto-restart)

Run the installer. It auto-detects node, hermes, your user/home, and the repo
path, writes the launchd plist for you, and starts the service:

```bash
chmod +x install-service.sh hermes-gateway-catalina.sh
./install-service.sh
```

It prints what it detected and whether the service came up with a live PID.
On every (re)start the service runs the fix first (a no-op when healthy), so
the Catalina patch survives `hermes update`.

Manage it:

```bash
launchctl list | grep com.hermes.gateway-catalina   # a number = running
cat /tmp/hermes-gateway-catalina.out.log            # what it did
./install-service.sh --uninstall                    # stop and remove
./install-service.sh --print                        # preview the plist only
```

Prefer to write the plist by hand? Use `com.hermes.gateway-catalina.plist.example`
as a reference — but the installer is the easy path.

> ⚠️ **Run only one gateway.** With the service running, don't also run
> `hermes gateway` by hand or a Docker gateway with WhatsApp enabled. Two
> gateways sharing `~/.hermes` fight over the WhatsApp session and the SQLite
> state. Pick one.

---

## Maintenance

The pinned npm version lives in one place — the `BAILEYS_VERSION` variable at
the top of `fix-whatsapp-catalina.sh` — and was validated against the `bridge.js`
Hermes ships as of mid-2026. If a future Hermes update moves the bridge to a
Baileys version with a different API, bump that variable to the matching npm
release. Find the latest with:

```bash
npm view @whiskeysockets/baileys version
```

The script pins an exact version on purpose rather than auto-grabbing "latest":
a silent auto-upgrade could install a Baileys whose API the shipped `bridge.js`
doesn't match. An explicit, visible version that you bump deliberately is safer
than magic that can break quietly.

---

## Troubleshooting

**`Baileys ... needs Node >= 20`** — You're on Node 18 (or older). `nvm use 20`.
Verify with `node --version`.

**`WhatsApp bridge not found at ~/.hermes/scripts/whatsapp-bridge`** — Hermes
hasn't created the bridge yet. Enable WhatsApp in Hermes once (it'll fail to
install on Catalina, but it creates the directory), then run the fix.

**esbuild crash still appears** — Something in the dependency tree is still
building from source. Confirm `package.json` now shows a plain version for
`@whiskeysockets/baileys` (not a `WhiskeySockets/Baileys#...` ref):
`grep baileys ~/.hermes/scripts/whatsapp-bridge/package.json`.

**Bridge installs but won't connect / API errors at runtime** — The pinned
Baileys version may not match the shipped `bridge.js`. Try the version closest
to the commit Hermes pins (check `package.json.hermes-original`), or the current
npm `latest`.

**`hermes gateway` works but says the bridge failed** — Check the real npm error
by installing directly:
`cd ~/.hermes/scripts/whatsapp-bridge && npm install`. The gateway swallows the
detailed error; a direct install shows it.

---

## Why not just use Docker / a Linux box?

Both work and are arguably more "durable." This repo is for the case where you
want WhatsApp running on the **native Catalina install you already have**, with
no extra moving parts — and where understanding and fixing the actual root cause
is worth more than working around it. If you'd rather isolate WhatsApp in a
container or move Hermes to a Linux host, those are valid too; this just isn't
that.

---

## Security note

`npm audit` on the bridge reports a **high-severity advisory in `link-preview-js`**
([GHSA-4gp8-rjrq-ch6q](https://github.com/advisories/GHSA-4gp8-rjrq-ch6q) — SSRF
via IPv6 / internal loopback addresses), with **no fix available** upstream.

Important context:

- **It comes from Baileys, not from this repo.** `link-preview-js` is a
  dependency of `@whiskeysockets/baileys`, which pins a vulnerable version.
  *Any* Hermes install with WhatsApp has this exact advisory — on Catalina or
  not, with this fix or not. This repo doesn't introduce it; it just doesn't
  hide it. You can't remove it without removing Baileys (uninstalling it just
  makes Baileys reinstall it).
- **The practical risk is low in the bridge's allowlist/self-chat mode.** The
  SSRF vector requires the bot to fetch a link-preview for an attacker-supplied
  URL pointing at your internal network. The bridge only processes messages from
  numbers you explicitly allow (`WHATSAPP_ALLOWED_USERS`), so an attacker would
  have to be on your own allowlist sending you a malicious internal URL.
- **Mitigation:** keep the bridge in allowlist mode (the default), don't expose
  it as an open/public bot, and don't add untrusted numbers to the allowlist.
  Watch the [Baileys advisories](https://github.com/WhiskeySockets/Baileys/security)
  for an upstream bump and update `BAILEYS_VERSION` when one lands.

This is documented rather than silenced because anyone running `npm audit` will
see it — better to explain the real exposure than to pretend it isn't there.

---

## License

MIT. See [LICENSE](LICENSE).

## Disclaimer

Not affiliated with Nous Research or the Baileys project. Baileys is an
unofficial WhatsApp library; use it in accordance with WhatsApp's Terms of
Service and at your own risk.
