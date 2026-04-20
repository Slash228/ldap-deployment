set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8080}"
KC_REALM="${KC_REALM:-dnp-realm}"
KC_CLIENT="${KC_CLIENT:-demo-app}"
KC_CLIENT_SECRET="${KC_CLIENT_SECRET:-demo-app-secret}"
APP_URL="${APP_URL:-http://localhost:3000}"
LLDAP_URL="${LLDAP_URL:-http://localhost:17170}"

TOKEN_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token"
USERINFO_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/userinfo"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

FAILED=0

log()  { echo -e "$*"; }
ok()   { log "${GREEN}[✓]${RESET} $*"; }
fail() { log "${RED}[✗]${RESET} $*"; FAILED=1; }
warn() { log "${YELLOW}[!]${RESET} $*"; }
info() { log "${CYAN}[→]${RESET} $*"; }

log "${BOLD}════════════════════════════════════════${RESET}"
log "${BOLD}  LDAP Deployment — Smoke Test${RESET}"
log "${BOLD}  $(date)${RESET}"
log "${BOLD}════════════════════════════════════════${RESET}"
log ""

get_token() {
    curl -sf --max-time 10 \
        --data-urlencode "client_id=${KC_CLIENT}" \
        --data-urlencode "client_secret=${KC_CLIENT_SECRET}" \
        --data-urlencode "username=$1" \
        --data-urlencode "password=$2" \
        --data-urlencode "grant_type=password" \
        --data-urlencode "scope=openid profile email" \
        "${TOKEN_ENDPOINT}" 2>/dev/null || true
}

get_groups() {
    curl -sf --max-time 10 \
        -H "Authorization: Bearer $1" \
        "${USERINFO_ENDPOINT}" 2>/dev/null \
    | python3 -c "import sys,json; g=[x.strip('/') for x in json.load(sys.stdin).get('groups',[])]; print(','.join(g))" 2>/dev/null || true
}

# ── 1. Service reachability ────────────────────────────────────────────────────
info "Checking services..."

curl -sf --max-time 5 "${LLDAP_URL}/health" -o /dev/null 2>/dev/null \
    && ok "LLDAP      ${LLDAP_URL}/health" \
    || fail "LLDAP not reachable at ${LLDAP_URL}/health"

curl -sf --max-time 5 "${KC_URL}/realms/${KC_REALM}" -o /dev/null 2>/dev/null \
    && ok "Keycloak   ${KC_URL}/realms/${KC_REALM}" \
    || fail "Keycloak realm not reachable"

curl -sf --max-time 5 "${APP_URL}" -o /dev/null 2>/dev/null \
    && ok "Demo App   ${APP_URL}" \
    || fail "Demo app not reachable at ${APP_URL}"

# ── 2. alice login + groups ────────────────────────────────────────────────────
log ""
info "Testing alice / alice1234 (admins group)..."

resp=$(get_token "alice" "alice1234")
tok=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

if [[ -z "$tok" ]]; then
    fail "alice: no token — check KC_CLIENT_SECRET and that directAccessGrants is enabled"
else
    ok "alice: token obtained"
    groups=$(get_groups "$tok")
    if [[ "$groups" == "admins" ]]; then
        ok "alice: groups=[admins] ✓"
    else
        fail "alice: groups=[${groups:-none}], expected [admins]"
    fi
fi

# ── 3. Wrong password ──────────────────────────────────────────────────────────
log ""
info "Testing wrong password rejection..."

resp=$(get_token "alice" "DEFINITELY_WRONG_PASS!")
bad_tok=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
err=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null || true)

if [[ -n "$bad_tok" ]]; then
    fail "alice with wrong password: token ISSUED — security breach!"
elif [[ -n "$err" ]]; then
    ok "alice with wrong password: rejected with '${err}'"
else
    ok "alice with wrong password: no token issued"
fi

# ── 4. mallory — no group ──────────────────────────────────────────────────────
log ""
info "Testing mallory / mallory1234 (no LDAP group)..."

resp=$(get_token "mallory" "mallory1234")
mall_tok=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

if [[ -z "$mall_tok" ]]; then
    ok "mallory: blocked at Keycloak (no token issued)"
else
    groups=$(get_groups "$mall_tok")
    if [[ -z "$groups" ]]; then
        ok "mallory: token issued, groups=[] — app will redirect to /unauthorized"

        # Confirm /unauthorized page exists
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${APP_URL}/unauthorized" 2>/dev/null || echo "000")
        [[ "$code" =~ ^(200|302)$ ]] \
            && ok "mallory: /unauthorized page → HTTP ${code}" \
            || warn "mallory: /unauthorized returned HTTP ${code}"
    else
        fail "mallory: unexpectedly has groups=[${groups}]"
    fi
fi

# ── Result ─────────────────────────────────────────────────────────────────────
log ""
log "${BOLD}════════════════════════════════════════${RESET}"
if [[ $FAILED -eq 0 ]]; then
    log "${GREEN}${BOLD}  ✓ Stack is healthy!${RESET}"
    log ""
    log "  Run full validation:"
    log "    bash scripts/validation/run_validation.sh"
else
    log "${RED}${BOLD}  ✗ Smoke test FAILED — fix issues before full validation${RESET}"
    log ""
    log "  Common fixes:"
    log "    - Wrong KC_CLIENT_SECRET: check docker/keycloak/realm-export.json → 'secret'"
    log "    - directAccessGrants disabled: realm-export.json → directAccessGrantsEnabled"
    log "    - Keycloak not ready: wait 30s and retry"
    exit 1
fi
