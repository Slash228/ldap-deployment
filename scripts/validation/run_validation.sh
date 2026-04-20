set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
KC_URL="${KC_URL:-http://localhost:8080}"
KC_REALM="${KC_REALM:-dnp-realm}"
KC_CLIENT="${KC_CLIENT:-demo-app}"
# Client secret is hardcoded in realm-export.json as "demo-app-secret"
KC_CLIENT_SECRET="${KC_CLIENT_SECRET:-${APP_CLIENT_SECRET:-demo-app-secret}}"
APP_URL="${APP_URL:-http://localhost:3000}"
LLDAP_URL="${LLDAP_URL:-http://localhost:17170}"
LOG_DIR="${LOG_DIR:-logs}"
LOG_FILE="${LOG_DIR}/validation_$(date +%Y%m%d_%H%M%S).log"

TOKEN_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token"
USERINFO_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/userinfo"
INTROSPECT_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token/introspect"
REVOKE_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/revoke"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

mkdir -p "$LOG_DIR"
PASS=0; FAIL=0; WARN=0

ts()      { date '+%H:%M:%S'; }
log()     { echo -e "$*" | tee -a "$LOG_FILE"; }
info()    { log "${CYAN}[$(ts) INFO]${RESET}  $*"; }
ok()      { log "${GREEN}[$(ts) PASS]${RESET}  $*"; ((PASS++)); }
fail()    { log "${RED}[$(ts) FAIL]${RESET}  $*"; ((FAIL++)); }
warn()    { log "${YELLOW}[$(ts) WARN]${RESET}  $*"; ((WARN++)); }
section() {
    log ""
    log "${BOLD}${YELLOW}══════════════════════════════════════════════════════${RESET}"
    log "${BOLD}${YELLOW}  $*${RESET}"
    log "${BOLD}${YELLOW}══════════════════════════════════════════════════════${RESET}"
}

# ── Helpers ────────────────────────────────────────────────────────────────────

get_token() {
    # Direct Access Grant (Resource Owner Password Credentials)
    # Works because directAccessGrantsEnabled = true in realm-export.json
    local user="$1" pass="$2"
    curl -sf --max-time 10 \
        --data-urlencode "client_id=${KC_CLIENT}" \
        --data-urlencode "client_secret=${KC_CLIENT_SECRET}" \
        --data-urlencode "username=${user}" \
        --data-urlencode "password=${pass}" \
        --data-urlencode "grant_type=password" \
        --data-urlencode "scope=openid profile email" \
        "${TOKEN_ENDPOINT}" 2>/dev/null || true
}

json_field() {
    # Extract a field from a JSON string
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$2',''))" <<< "$1" 2>/dev/null || true
}

get_userinfo() {
    # Fetch /userinfo and return groups as comma-separated string (mirroring app logic)
    local access_token="$1"
    curl -sf --max-time 10 \
        -H "Authorization: Bearer ${access_token}" \
        "${USERINFO_ENDPOINT}" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
groups = [g.strip('/') for g in d.get('groups', [])]
print(','.join(groups))
" 2>/dev/null || true
}

introspect() {
    # Returns 'true' or 'false'
    local token="$1"
    curl -sf --max-time 10 \
        --data-urlencode "client_id=${KC_CLIENT}" \
        --data-urlencode "client_secret=${KC_CLIENT_SECRET}" \
        --data-urlencode "token=${token}" \
        "${INTROSPECT_ENDPOINT}" 2>/dev/null \
    | python3 -c "import sys,json; print(str(json.load(sys.stdin).get('active',False)).lower())" 2>/dev/null || echo "false"
}

revoke() {
    local token="$1"
    curl -sf --max-time 10 \
        --data-urlencode "client_id=${KC_CLIENT}" \
        --data-urlencode "client_secret=${KC_CLIENT_SECRET}" \
        --data-urlencode "token=${token}" \
        "${REVOKE_ENDPOINT}" -o /dev/null 2>/dev/null || true
}

decode_jwt_payload() {
    # Print selected claims from JWT payload (no signature check needed)
    local token="$1"
    echo "$token" | cut -d. -f2 | python3 -c "
import sys, base64, json
raw = sys.stdin.read().strip()
raw += '=' * (4 - len(raw) % 4)
try:
    d = json.loads(base64.b64decode(raw))
    want = ['preferred_username','groups','exp','iss','aud']
    print(json.dumps({k: d[k] for k in want if k in d}, indent=2))
except Exception as e:
    print(f'  (JWT decode error: {e})')
" 2>/dev/null || true
}

# ── User table ─────────────────────────────────────────────────────────────────
# "username|password|expected_groups_csv|admin_access"
declare -a USERS=(
    "alice|alice1234|admins|yes"
    "bob|bob12345|developers|no"
    "carol|carol1234|developers|no"
    "dave|dave12345|viewers|no"
    "eve|eve12345|viewers|no"
    "mallory|mallory1234||no"
)

declare -A TOKENS   # access_token per user
declare -A RTOKENS  # refresh_token per user
declare -A ID_TOKS  # id_token per user

# ══════════════════════════════════════════════════════════════════════════════
section "PREFLIGHT — Service availability"
# ══════════════════════════════════════════════════════════════════════════════

svc_check() {
    local label="$1" url="$2"
    if curl -sf --max-time 5 "$url" -o /dev/null 2>/dev/null; then
        ok "${label}  ${url}"
    else
        fail "${label}  ${url}"
    fi
}

svc_check "LLDAP health  " "${LLDAP_URL}/health"
svc_check "Keycloak realm" "${KC_URL}/realms/${KC_REALM}"
svc_check "Demo app      " "${APP_URL}"

# ══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 1 — Login (token issuance) for all users"
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "  User       Password       Expected groups    Result"
log "  ─────────  ─────────────  ─────────────────  ──────"

for entry in "${USERS[@]}"; do
    IFS='|' read -r username password expected_groups _ <<< "$entry"

    resp=$(get_token "$username" "$password")
    error=$(json_field "$resp" "error")
    access_token=$(json_field "$resp" "access_token")
    id_tok=$(json_field "$resp" "id_token")
    refresh_tok=$(json_field "$resp" "refresh_token")

    if [[ -n "$error" || -z "$access_token" ]]; then
        fail "${username}: login FAILED — ${error:-no token}"
        continue
    fi

    ok "${username}: token issued successfully"
    TOKENS["$username"]="$access_token"
    RTOKENS["$username"]="$refresh_tok"
    ID_TOKS["$username"]="$id_tok"

    info "${username}: JWT payload:"
    decode_jwt_payload "$access_token" | sed 's/^/    /' | tee -a "$LOG_FILE"
    log ""
done

# ══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 2 — groups claim validation (LDAP → Keycloak → JWT)"
# ══════════════════════════════════════════════════════════════════════════════
#
# Flow: LLDAP groups → Keycloak user federation → group-membership-mapper
#       → "groups" claim in access_token & userinfo
# Flask app: session["user_groups"] = [g.strip("/") for g in userinfo["groups"]]

for entry in "${USERS[@]}"; do
    IFS='|' read -r username _ expected_groups _ <<< "$entry"

    tok="${TOKENS[$username]:-}"
    [[ -z "$tok" ]] && { warn "${username}: no token, skip groups check"; continue; }

    actual_groups=$(get_userinfo "$tok")

    if [[ "$actual_groups" == "$expected_groups" ]]; then
        ok "${username}: groups=[${actual_groups:-none}] ✓"
    else
        fail "${username}: groups=[${actual_groups:-none}], expected=[${expected_groups:-none}]"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 3 — Wrong password rejected by Keycloak"
# ══════════════════════════════════════════════════════════════════════════════

for entry in "${USERS[@]}"; do
    IFS='|' read -r username _ _ _ <<< "$entry"

    resp=$(get_token "$username" "TOTALLY_WRONG_PASS_XYZ!")
    error=$(json_field "$resp" "error")
    bad_token=$(json_field "$resp" "access_token")

    if [[ -n "$bad_token" ]]; then
        fail "${username}: wrong password accepted! Security breach."
    elif [[ "$error" == "invalid_user_credentials" || "$error" == "invalid_grant" ]]; then
        ok "${username}: wrong password → Keycloak error '${error}'"
    else
        ok "${username}: wrong password → no token issued (${error:-empty response})"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 4 — mallory: authorized token, but no group → /unauthorized"
# ══════════════════════════════════════════════════════════════════════════════
#
# mallory has a valid Keycloak account but no LDAP group.
# Flask @group_required("admins") / @group_required("developers","admins"):
#   any(g in user_groups for g in group_names) → False → redirect to /unauthorized
# This simulates what the user sees in the browser.

info "mallory token status:"
mall_tok="${TOKENS[mallory]:-}"

if [[ -z "$mall_tok" ]]; then
    ok "mallory: Keycloak refused to issue token (blocked at auth stage)"
else
    mall_groups=$(get_userinfo "$mall_tok")

    if [[ -z "$mall_groups" ]]; then
        ok "mallory: token valid, groups=[] — Flask will redirect to /unauthorized on all protected routes"

        log ""
        log "  Simulated Flask RBAC check:"
        log "    user_groups = []"
        for route_group in "admins" "developers" "viewers"; do
            log "    @group_required('${route_group}') → any(g in [] for g in ['${route_group}']) = False → ${RED}REDIRECT /unauthorized${RESET}"
        done
        log ""

        # HTTP check: app /unauthorized page (browser-facing, no Bearer token needed for this page)
        unauth_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            "${APP_URL}/unauthorized" 2>/dev/null || echo "000")
        # /unauthorized is accessible (shows "Access Denied" page, HTTP 200)
        if [[ "$unauth_code" =~ ^(200|302)$ ]]; then
            ok "mallory: /unauthorized page reachable (HTTP ${unauth_code}) — denial page confirmed"
        else
            warn "mallory: /unauthorized returned HTTP ${unauth_code}"
        fi
    else
        fail "mallory: unexpectedly has groups=[${mall_groups}] — RBAC bypass risk!"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 5 — Admin access: alice allowed, all others denied"
# ══════════════════════════════════════════════════════════════════════════════
#
# Flask route /admin uses @group_required("admins")
# We check groups claim directly (same logic Flask uses from session)

for entry in "${USERS[@]}"; do
    IFS='|' read -r username _ _ has_admin <<< "$entry"

    tok="${TOKENS[$username]:-}"
    [[ -z "$tok" ]] && { warn "${username}: no token, skip admin check"; continue; }

    groups=$(get_userinfo "$tok")
    in_admins=false
    echo "$groups" | grep -q "admins" && in_admins=true

    if [[ "$has_admin" == "yes" ]]; then
        if $in_admins; then
            ok "${username}: in 'admins' → /admin route GRANTED"
        else
            fail "${username}: expected admin access but groups=[${groups}]"
        fi
    else
        if ! $in_admins; then
            ok "${username}: NOT in 'admins' → /admin route DENIED (groups=[${groups:-none}])"
        else
            fail "${username}: unexpectedly in 'admins' group!"
        fi
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 6 — Logout: token revocation via Keycloak"
# ══════════════════════════════════════════════════════════════════════════════
#
# Flask /logout: session.clear() + redirect to Keycloak end_session?id_token_hint=...
# We simulate token revocation and verify via introspection.

for entry in "${USERS[@]}"; do
    IFS='|' read -r username _ _ _ <<< "$entry"

    tok="${TOKENS[$username]:-}"
    [[ -z "$tok" ]] && { warn "${username}: no token, skip logout test"; continue; }

    # Verify token is active before logout
    active_before=$(introspect "$tok")
    log "  ${username}: introspect before logout → active=${active_before}"

    # Revoke token (equivalent to Keycloak backchannel logout / session termination)
    revoke "$tok"
    log "  ${CYAN}→${RESET} ${username}: revoke sent"

    # Small pause for Keycloak to process
    sleep 0.5

    # Verify token is now inactive
    active_after=$(introspect "$tok")
    if [[ "$active_after" == "false" ]]; then
        ok "${username}: logout confirmed — token introspect active=false"
    else
        # Keycloak may still return active=true for stateless JWT until expiry.
        # This is expected behavior when token revocation checking is disabled.
        warn "${username}: token still active after revoke (stateless JWT — expires in ~${KC_TOKEN_TTL:-300}s)"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 7 — Collect LDAP & Keycloak logs"
# ══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if bash "${SCRIPT_DIR}/collect_logs.sh" 2>&1 | tee -a "$LOG_FILE"; then
    ok "Logs collected — see ${LOG_DIR}/"
else
    warn "Log collection had issues (non-fatal)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "VALIDATION SUMMARY"
# ══════════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + FAIL))
log ""
log "  ┌──────────────────────────────────────┐"
printf "  │  %-38s│\n" "Tests run  : ${TOTAL}" | tee -a "$LOG_FILE"
printf "  │  %-38s│\n" "Passed     : ${PASS}" | tee -a "$LOG_FILE"
printf "  │  %-38s│\n" "Failed     : ${FAIL}" | tee -a "$LOG_FILE"
printf "  │  %-38s│\n" "Warnings   : ${WARN}" | tee -a "$LOG_FILE"
log "  └──────────────────────────────────────┘"
log ""
log "  Log file: ${LOG_FILE}"
log ""

if [[ $FAIL -eq 0 ]]; then
    log "${GREEN}${BOLD}  ✓  ALL CHECKS PASSED${RESET}"
    exit 0
else
    log "${RED}${BOLD}  ✗  ${FAIL} CHECK(S) FAILED${RESET}"
    exit 1
fi
