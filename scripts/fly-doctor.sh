#!/usr/bin/env bash
# Read-only Fly.io diagnostics for this repository.
#
#   bash scripts/fly-doctor.sh [app-name]
#
# It never deploys, scales, or changes anything: it inspects fly.toml, the local
# flyctl install/auth, DNS for <app>.fly.dev, the deployed config, Machines,
# health checks, secrets (names only, never values), recent logs and the public
# /healthz endpoint. Run it where flyctl is installed and logged in.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '!! %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- app name: argument, then fly.toml --------------------------------------
app="${1:-}"
if [ -z "$app" ] && [ -f fly.toml ]; then
    app="$(sed -nE "s/^app[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" fly.toml | head -1)"
fi
if [ -z "$app" ]; then
    warn "No app name: pass one as an argument or set 'app' in fly.toml."
    exit 1
fi

# --- local configuration ----------------------------------------------------
say "fly.toml (local checkout)"
info "app = $app"
port="$(sed -nE "s/^[[:space:]]*PORT[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" fly.toml | head -1)"
internal_port="$(sed -nE 's/^[[:space:]]*internal_port[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' fly.toml | head -1)"
auto_stop="$(sed -nE "s/^[[:space:]]*auto_stop_machines[[:space:]]*=[[:space:]]*['\"]?([^'\"[:space:]]+)['\"]?.*/\1/p" fly.toml | head -1)"
min_machines="$(sed -nE 's/^[[:space:]]*min_machines_running[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' fly.toml | head -1)"
info "[env] PORT = ${port:-<unset>}   internal_port = ${internal_port:-<unset>}"
if [ -n "$port" ] && [ -n "$internal_port" ] && [ "$port" != "$internal_port" ]; then
    warn "PORT and internal_port differ — Fly's proxy will have no listener and the app looks dead."
else
    info "port pairing: ok"
fi
info "auto_stop_machines = ${auto_stop:-<default>}   min_machines_running = ${min_machines:-<default>}"
if [ "${auto_stop:-}" = "stop" ] || [ "${auto_stop:-}" = "suspend" ] || [ "${min_machines:-1}" = "0" ]; then
    warn "scale-to-zero is enabled — a stopped Machine loses the in-memory provisioning loop."
fi
if git rev-parse --git-dir >/dev/null 2>&1; then
    if ! git diff --quiet -- fly.toml 2>/dev/null; then
        warn "fly.toml has uncommitted changes — a regenerated fly.toml usually drops [env] PORT."
    fi
fi

# --- flyctl ----------------------------------------------------------------
say "flyctl"
flyctl_ok=0
if ! have flyctl; then
    warn "flyctl not found. Install it and rerun: https://fly.io/docs/flyctl/install/"
else
    info "$(flyctl version 2>&1 | head -1)"
    who="$(flyctl auth whoami 2>&1 | head -1)"
    case "$who" in
        *rror*|*"not logged in"*|'') warn "not authenticated: run 'flyctl auth login'" ;;
        *) info "authenticated as $who"; flyctl_ok=1 ;;
    esac
fi

# --- DNS -------------------------------------------------------------------
say "DNS"
if have dig; then
    dns="$(dig +short "$app.fly.dev" 2>/dev/null | head -3)"
elif have getent; then
    dns="$(getent hosts "$app.fly.dev" 2>/dev/null | awk '{print $1}' | head -3)"
else
    dns=""
fi
if [ -n "$dns" ]; then
    info "$app.fly.dev -> $(echo "$dns" | tr '\n' ' ')"
else
    warn "$app.fly.dev does not resolve. No Fly app is bound to that hostname: it was never"
    warn "created, was destroyed, or 'fly launch' chose a different name. Check: fly apps list"
    warn "(on a restricted network or VPN, confirm with: dig @1.1.1.1 +short $app.fly.dev)"
fi

# --- deployed state --------------------------------------------------------
if [ "$flyctl_ok" = 1 ]; then
    say "Deployed config"
    flyctl config show -a "$app" 2>&1 \
        | grep -E '^[[:space:]]*(app|PORT|internal_port|auto_stop_machines|min_machines_running)' \
        | sed 's/^/   /' || warn "could not read the deployed config (does the app exist?)"

    say "Status"
    flyctl status -a "$app" 2>&1 | sed 's/^/   /'

    say "Machines (this app needs exactly one)"
    flyctl machine list -a "$app" 2>&1 | sed 's/^/   /'

    say "Health checks"
    flyctl checks list -a "$app" 2>&1 | sed 's/^/   /'

    say "Secrets (names only)"
    flyctl secrets list -a "$app" 2>&1 | sed 's/^/   /'
    case "$(flyctl secrets list -a "$app" 2>&1)" in
        *APP_PASSWORD*) info "APP_PASSWORD is set — the UI and API ask for Basic Auth." ;;
        *) warn "APP_PASSWORD is not set — anyone who finds the URL can drive your OCI account." ;;
    esac

    say "Recent logs"
    if flyctl logs --help >/dev/null 2>&1; then
        timeout 12 flyctl logs --no-tail -a "$app" 2>&1 | tail -40 | sed 's/^/   /'
    else
        flyctl logs -a "$app" 2>&1 | tail -40 | sed 's/^/   /'
    fi
fi

# --- public endpoint -------------------------------------------------------
say "Public endpoint"
url="https://$app.fly.dev/healthz"
if ! have curl; then
    info "curl not installed; open $url in a browser."
else
    body="$(mktemp 2>/dev/null || echo /tmp/fly-health.$$)"
    code="$(curl -sS -m 15 -o "$body" -w '%{http_code}' "$url" 2>/dev/null)"
    if [ -z "$code" ]; then code="000"; fi
    info "GET $url -> HTTP $code"
    if [ -s "$body" ]; then head -5 "$body" | sed 's/^/   /'; fi
    rm -f "$body"
    case "$code" in
        200) info "healthy: Fly is routing to a Machine that answers on the right port" ;;
        502|503|504)
            warn "Fly's proxy is up but no Machine answered. Either the app has no started"
            warn "Machine (fly status) or the process listens on a different port than"
            warn "internal_port (fly logs should show 'Listening at: ...')."
            ;;
        000)
            warn "no response at all: the hostname does not resolve, or the connection failed."
            ;;
        *)
            info "unexpected status; see the body above and 'fly logs'."
            ;;
    esac
fi

# --- what to do next -------------------------------------------------------
say "If it is still not healthy"
cat <<EOF
   flyctl auth login
   flyctl apps list                                  # find the real app name
   flyctl apps create $app                           # only if it does not exist
   flyctl secrets set APP_PASSWORD='choose-a-long-password' -a $app
   flyctl deploy --ha=false                          # one Machine, from this repo
   flyctl status -a $app && flyctl logs -a $app
   curl -fsS https://$app.fly.dev/healthz
EOF
