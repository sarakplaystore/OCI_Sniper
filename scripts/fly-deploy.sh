#!/usr/bin/env bash
# Deploy this repository to Fly.io in one command.
#
#   bash scripts/fly-deploy.sh [app-name]
#
# Steps, in order:
#   1. check flyctl is installed and authenticated
#   2. create the app if it does not exist (name from fly.toml unless passed)
#   3. make sure APP_PASSWORD is a secret (prompts; never in argv or history)
#   4. flyctl deploy --remote-only --ha=false  (one Machine: state is per process)
#   5. scale back to one Machine if there is somehow more
#   6. wait for https://<app>.fly.dev/healthz to answer
#
# Everything is idempotent: rerunning it redeploys and re-verifies. For a
# read-only check of an existing deployment use scripts/fly-doctor.sh.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '!! %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

config_app() {
    sed -nE "s/^app[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"].*/\1/p" fly.toml | head -1
}

[ -f fly.toml ] || die "fly.toml not found — run this from the repository root."

app="${1:-$(config_app)}"
[ -n "$app" ] || die "No app name: pass one as an argument or set 'app' in fly.toml."

say "Preflight"
info "repository: $REPO_ROOT"
info "app: $app (fly.toml says: $(config_app))"
command -v flyctl >/dev/null 2>&1 || die "flyctl is not installed: https://fly.io/docs/flyctl/install/"
flyctl version 2>/dev/null | head -1 | sed 's/^/   /'
if ! flyctl auth whoami >/dev/null 2>&1; then
    die "not logged in — run 'flyctl auth login' (or 'flyctl auth signup') first."
fi
info "authenticated as $(flyctl auth whoami 2>/dev/null | head -1)"

if [ "$app" != "$(config_app)" ]; then
    warn "app name differs from fly.toml ($(config_app)) — edit fly.toml so CI deploys the same app."
fi

say "App"
if flyctl apps list 2>/dev/null | awk 'NR > 1 && NF {print $1}' | grep -qx -- "$app"; then
    info "app '$app' exists"
else
    warn "app '$app' does not exist in this organisation"
    flyctl apps create "$app" || die "could not create '$app' — pick another name and update fly.toml"
    info "created '$app'"
fi

say "APP_PASSWORD"
if flyctl secrets list -a "$app" 2>/dev/null | awk 'NR > 1 && NF {print $1}' | grep -qx APP_PASSWORD; then
    info "APP_PASSWORD is already set"
else
    warn "APP_PASSWORD is not set — anyone who finds the URL could drive your OCI account"
    password=""
    if [ -t 0 ]; then
        printf '   choose an APP_PASSWORD (hidden; Enter to skip): '
        read -rs password
        printf '\n'
    fi
    if [ -n "$password" ]; then
        # `secrets import` reads from stdin, so the value never lands in argv or
        # in shell history.
        printf 'APP_PASSWORD=%s\n' "$password" | flyctl secrets import -a "$app" \
            || die "could not store APP_PASSWORD"
        info "APP_PASSWORD stored"
    else
        warn "skipped — set it later with: flyctl secrets set APP_PASSWORD='…' -a $app"
    fi
    unset password
fi

say "Deploy"
info "building on Fly's builders, one Machine"
#   --remote-only : no Docker daemon needed locally
#   --ha=false    : Fly creates two Machines by default, and each one would run
#                   its own provisioning loop and log store
#   --wait-timeout: fail if the Machine never passes the /healthz check
flyctl deploy --remote-only --ha=false --wait-timeout=5m -a "$app" \
    || die "flyctl deploy failed — read the output above, then: flyctl logs -a $app"

say "Machines"
machines="$(flyctl machine list -a "$app" 2>/dev/null | awk 'NR > 1 && NF {print $1}')"
count="$(printf '%s\n' "$machines" | grep -c . || true)"
info "found ${count:-0} Machine(s)"
if [ "${count:-0}" -gt 1 ]; then
    warn "more than one Machine — each would run its own loop, logs and status"
    flyctl scale count 1 -a "$app" --yes \
        || warn "could not scale down; run: flyctl scale count 1 -a $app"
fi

say "Verify"
url="https://$app.fly.dev/healthz"
info "GET $url"
if ! command -v curl >/dev/null 2>&1; then
    info "curl is not installed — open $url in a browser."
    exit 0
fi
if curl -fsS --retry 8 --retry-all-errors --retry-delay 10 --max-time 20 "$url"; then
    printf '\n'
    info "deployed and reachable — open https://$app.fly.dev"
else
    warn "the deploy finished but $url did not answer"
    warn "next: bash scripts/fly-doctor.sh $app"
    exit 1
fi
