#!/usr/bin/env bash
# setup-github-app.sh — one-command setup for the stellar-docs-bot GitHub App.
#
# Registers a GitHub App via GitHub's app-manifest flow so the PR agent and issue agent
# post as ONE branded bot identity instead of github-actions[bot]. You click exactly twice
# in the browser; this script does everything else:
#
#   1. Starts a tiny local web server, then opens GitHub's "create app from manifest" page.
#        -> YOU click "Create GitHub App"                                 (browser click #1)
#   2. GitHub redirects back to the local server with a one-time code. The script exchanges
#      it (POST /app-manifests/{code}/conversions) for the App ID + private key and stores
#      them as repo secrets (APP_ID, APP_PRIVATE_KEY) via `gh secret set`. Nothing is
#      copy/pasted and the private key is never printed.
#   3. Opens the app's install page.
#        -> YOU pick the repo and click "Install"                         (browser click #2)
#
# Safe to re-run: if this script already created an app it reuses it (re-sets the secrets)
# instead of registering a duplicate. Use --force-new to register a fresh app.
#
# Usage:
#   ./setup-github-app.sh                 # normal run
#   ./setup-github-app.sh --force-new     # ignore a previously created app
#   REPO=owner/name ./setup-github-app.sh # target a different repo's secrets

set -euo pipefail
umask 077

# ── config (env-overridable) ──────────────────────────────────────────────────────────
REPO="${REPO:-kaankacar/stellar-docs}"          # repo whose workflows act as the app
APP_BASE_NAME="${APP_NAME:-stellar-docs-bot}"   # desired app name (random suffix if taken)
STATE_DIR="${STATE_DIR:-$HOME/.config/stellar-docs-bot}"  # key + metadata live here, outside any repo
PORT_FIRST=8377                                  # first port tried for the local callback server
TIMEOUT_SECS=600                                 # max wait for the browser "Create" click

FORCE_NEW=0
case "${1:-}" in
  --force-new) FORCE_NEW=1 ;;
  -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1 (try --help)"; exit 2 ;;
esac

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ── preflight ─────────────────────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run: gh auth login"
gh repo view "$REPO" --json name >/dev/null || die "cannot access repo $REPO with the current gh login"

# Local server runtime: python3 preferred, node fallback (checked with `which`).
if which python3 >/dev/null 2>&1; then RUNTIME=python3
elif which node >/dev/null 2>&1; then RUNTIME=node
else die "need python3 or node for the local callback server (neither found)"
fi
log "using $RUNTIME for the local callback server"

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── tiny JSON helpers (no jq dependency; reuse the chosen runtime) ────────────────────
json_get() {  # json_get FILE KEY -> prints value
  if [ "$RUNTIME" = python3 ]; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
  else
    node -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log(d[process.argv[2]]);' "$1" "$2"
  fi
}
json_extract_to_file() {  # json_extract_to_file SRC KEY DEST — value never touches stdout
  if [ "$RUNTIME" = python3 ]; then
    python3 -c 'import json,sys; open(sys.argv[3],"w").write(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2" "$3"
  else
    node -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));fs.writeFileSync(process.argv[3],d[process.argv[2]]);' "$1" "$2" "$3"
  fi
}

open_url() {
  if which open >/dev/null 2>&1; then open "$1" >/dev/null 2>&1 || true
  elif which xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 || true
  fi
  echo "    $1"
}

set_secrets() {  # set_secrets APP_ID_VALUE PEM_FILE
  log "setting repo secrets on $REPO (APP_ID, APP_PRIVATE_KEY)"
  gh secret set APP_ID --repo "$REPO" --body "$1"
  gh secret set APP_PRIVATE_KEY --repo "$REPO" < "$2"
}

print_install_step() {  # print_install_step SLUG
  local url="https://github.com/apps/$1/installations/new"
  echo
  log "LAST STEP (browser click #2) — install the app on the repo:"
  open_url "$url"
  echo "    On that page choose 'Only select repositories', pick $REPO, and click Install."
}

soft_verify_install() {  # soft_verify_install SLUG — best-effort, never fails the script
  log "waiting for the install click (auto-checking for up to 2 minutes — Ctrl-C is safe here)..."
  local i found=""
  for i in $(seq 1 24); do
    if gh api /user/installations --paginate --jq '.installations[].app_slug' 2>/dev/null | grep -qx "$1"; then
      found=1; break
    fi
    sleep 5
  done
  if [ -n "$found" ]; then
    log "installation confirmed — all set. The agents now post as $1[bot]."
  else
    log "could not auto-confirm the installation (that check is best-effort)."
    echo "    If you clicked Install, you're done — the next PR/issue will be answered by $1[bot]."
  fi
}

# ── reuse a previously created app (idempotent re-runs) ───────────────────────────────
if [ "$FORCE_NEW" -eq 0 ] && [ -f "$STATE_DIR/app.json" ]; then
  SLUG="$(json_get "$STATE_DIR/app.json" slug)"
  APP_ID_VALUE="$(json_get "$STATE_DIR/app.json" id)"
  PEM_FILE="$STATE_DIR/$SLUG.private-key.pem"
  if [ -f "$PEM_FILE" ]; then
    log "found previously created app '$SLUG' (App ID $APP_ID_VALUE) — reusing it (use --force-new to register a fresh one)"
    set_secrets "$APP_ID_VALUE" "$PEM_FILE"
    print_install_step "$SLUG"
    soft_verify_install "$SLUG"
    exit 0
  fi
  log "found $STATE_DIR/app.json but its private key file is missing — registering a fresh app instead"
fi

# ── pick an app name that is free (slugs are global on GitHub) ────────────────────────
APP_NAME_FINAL="$APP_BASE_NAME"
name_taken() { gh api "apps/$1" >/dev/null 2>&1; }
while name_taken "$APP_NAME_FINAL"; do
  APP_NAME_FINAL="$APP_BASE_NAME-$(openssl rand -hex 2)"
done
log "app name: $APP_NAME_FINAL"

# ── pick a free localhost port ────────────────────────────────────────────────────────
port_free() {
  if [ "$RUNTIME" = python3 ]; then
    python3 -c 'import socket,sys
s=socket.socket()
try:
    s.bind(("127.0.0.1",int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()' "$1" 2>/dev/null
  else
    node -e 'const s=require("net").createServer();s.once("error",()=>process.exit(1));s.listen(Number(process.argv[1]),"127.0.0.1",()=>s.close(()=>process.exit(0)));' "$1" 2>/dev/null
  fi
}
PORT=""
for p in $(seq "$PORT_FIRST" $((PORT_FIRST + 20))); do
  if port_free "$p"; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || die "no free localhost port in $PORT_FIRST..$((PORT_FIRST + 20))"

# ── the app manifest ──────────────────────────────────────────────────────────────────
# The agents need: comment/label issues + PRs, merge PRs (contents). No webhook — the
# workflows react to repo events themselves — so the hook is registered inactive.
STATE_TOKEN="$(openssl rand -hex 16)"
POST_URL="https://github.com/settings/apps/new?state=$STATE_TOKEN"
cat > "$WORK/manifest.json" <<EOF
{
  "name": "$APP_NAME_FINAL",
  "url": "https://github.com/$REPO",
  "hook_attributes": { "url": "https://github.com/$REPO", "active": false },
  "redirect_url": "http://localhost:$PORT/callback",
  "public": false,
  "default_permissions": {
    "issues": "write",
    "pull_requests": "write",
    "contents": "write",
    "metadata": "read"
  },
  "default_events": ["issues", "pull_request"]
}
EOF

# ── local callback server (auto-submits the manifest form, captures the code) ─────────
cat > "$WORK/server.py" <<'PYEOF'
import html, http.server, sys, threading, urllib.parse

port, state, code_file, manifest_file, post_url = (
    int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
manifest = open(manifest_file).read()

PAGE = ("<!doctype html><html><head><meta charset='utf-8'>"
        "<title>stellar-docs-bot setup</title></head>"
        "<body onload=\"document.getElementById('f').submit()\" "
        "style='font-family:sans-serif;margin:3rem'>"
        "<h2>Sending the app manifest to GitHub&hellip;</h2>"
        "<p>If nothing happens, click the button.</p>"
        "<form id='f' action=\"{action}\" method='post'>"
        "<input type='hidden' name='manifest' value=\"{manifest}\">"
        "<button type='submit'>Continue to GitHub</button></form></body></html>").format(
            action=html.escape(post_url, quote=True),
            manifest=html.escape(manifest, quote=True))
OK_PAGE = ("<!doctype html><html><body style='font-family:sans-serif;margin:3rem'>"
           "<h2>App created &#10003;</h2><p>You can close this tab and return to the "
           "terminal — it finishes the rest automatically.</p></body></html>")
ERR_PAGE = ("<!doctype html><html><body style='font-family:sans-serif;margin:3rem'>"
            "<h2>State mismatch</h2><p>Unexpected callback — re-run the setup script."
            "</p></body></html>")

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def _send(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path in ("", "/"):
            self._send(200, PAGE)
            return
        if u.path == "/callback":
            q = urllib.parse.parse_qs(u.query)
            code = q.get("code", [""])[0]
            if q.get("state", [""])[0] != state or not code:
                self._send(400, ERR_PAGE)
                return
            with open(code_file, "w") as f:
                f.write(code)
            self._send(200, OK_PAGE)
            threading.Thread(target=server.shutdown, daemon=True).start()
            return
        self._send(404, "not found")

server = http.server.HTTPServer(("127.0.0.1", port), Handler)
server.serve_forever()
PYEOF

cat > "$WORK/server.js" <<'JSEOF'
const http = require("http");
const fs = require("fs");
const [port, state, codeFile, manifestFile, postUrl] = process.argv.slice(2);
const manifest = fs.readFileSync(manifestFile, "utf8");
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
const PAGE = "<!doctype html><html><head><meta charset='utf-8'>" +
  "<title>stellar-docs-bot setup</title></head>" +
  "<body onload=\"document.getElementById('f').submit()\" " +
  "style='font-family:sans-serif;margin:3rem'>" +
  "<h2>Sending the app manifest to GitHub&hellip;</h2>" +
  "<p>If nothing happens, click the button.</p>" +
  "<form id='f' action=\"" + esc(postUrl) + "\" method='post'>" +
  "<input type='hidden' name='manifest' value=\"" + esc(manifest) + "\">" +
  "<button type='submit'>Continue to GitHub</button></form></body></html>";
const OK_PAGE = "<!doctype html><html><body style='font-family:sans-serif;margin:3rem'>" +
  "<h2>App created &#10003;</h2><p>You can close this tab and return to the terminal — " +
  "it finishes the rest automatically.</p></body></html>";
const ERR_PAGE = "<!doctype html><html><body style='font-family:sans-serif;margin:3rem'>" +
  "<h2>State mismatch</h2><p>Unexpected callback — re-run the setup script.</p></body></html>";
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://localhost:" + port);
  const send = (st, body) => { res.writeHead(st, {"Content-Type": "text/html; charset=utf-8"}); res.end(body); };
  if (u.pathname === "/" || u.pathname === "") return send(200, PAGE);
  if (u.pathname === "/callback") {
    const code = u.searchParams.get("code") || "";
    if ((u.searchParams.get("state") || "") !== state || !code) return send(400, ERR_PAGE);
    fs.writeFileSync(codeFile, code);
    send(200, OK_PAGE);
    setTimeout(() => server.close(() => process.exit(0)), 300);
    return;
  }
  send(404, "not found");
});
server.listen(Number(port), "127.0.0.1");
JSEOF

if [ "$RUNTIME" = python3 ]; then
  python3 "$WORK/server.py" "$PORT" "$STATE_TOKEN" "$WORK/code" "$WORK/manifest.json" "$POST_URL" &
else
  node "$WORK/server.js" "$PORT" "$STATE_TOKEN" "$WORK/code" "$WORK/manifest.json" "$POST_URL" &
fi
SERVER_PID=$!

echo
log "YOUR TURN (browser click #1) — a page is opening that forwards the app manifest to GitHub:"
open_url "http://localhost:$PORT/"
echo "    Make sure the browser is logged in as the GitHub account that owns $REPO,"
echo "    then click the green 'Create GitHub App' button."
echo "    (If GitHub says the name is taken, just edit the name on that page and create —"
echo "    the rest of this script picks up whatever GitHub returns.)"
echo

# ── wait for the redirect with the one-time code ──────────────────────────────────────
waited=0
while [ ! -s "$WORK/code" ]; do
  kill -0 "$SERVER_PID" 2>/dev/null || [ -s "$WORK/code" ] || die "local callback server exited unexpectedly — re-run the script"
  [ "$waited" -ge "$TIMEOUT_SECS" ] && die "timed out after ${TIMEOUT_SECS}s waiting for the browser step — re-run the script"
  sleep 2; waited=$((waited + 2))
done
CODE="$(cat "$WORK/code")"
log "got the one-time code from GitHub — exchanging it for the app credentials"

# ── exchange the code: POST /app-manifests/{code}/conversions ─────────────────────────
gh api --method POST "app-manifests/$CODE/conversions" > "$WORK/conversion.json" \
  || die "code exchange failed (the code is single-use and expires after 1 hour) — re-run the script"

APP_ID_VALUE="$(json_get "$WORK/conversion.json" id)"
SLUG="$(json_get "$WORK/conversion.json" slug)"
CLIENT_ID="$(json_get "$WORK/conversion.json" client_id)"
HTML_URL="$(json_get "$WORK/conversion.json" html_url)"
log "created GitHub App '$SLUG' (App ID $APP_ID_VALUE) — $HTML_URL"

# Keep the private key + metadata OUTSIDE any repo, private to this user.
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
PEM_FILE="$STATE_DIR/$SLUG.private-key.pem"
json_extract_to_file "$WORK/conversion.json" pem "$PEM_FILE"
chmod 600 "$PEM_FILE"
cat > "$STATE_DIR/app.json" <<EOF
{ "id": $APP_ID_VALUE, "slug": "$SLUG", "client_id": "$CLIENT_ID", "html_url": "$HTML_URL", "repo": "$REPO" }
EOF
log "private key saved to $PEM_FILE (never printed, never committed)"

set_secrets "$APP_ID_VALUE" "$PEM_FILE"
print_install_step "$SLUG"
soft_verify_install "$SLUG"
