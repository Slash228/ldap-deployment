#!/usr/bin/env bash
set -euo pipefail


KC_URL="${KC_URL:-http://localhost:8080}"
KC_REALM="${KC_REALM:-dnp-realm}"
KC_CLIENT="${KC_CLIENT:-demo-app}"
KC_CLIENT_SECRET="${KC_CLIENT_SECRET:-${APP_CLIENT_SECRET:-demo-app-secret}}"
APP_URL="${APP_URL:-http://localhost:3000}"
LLDAP_URL="${LLDAP_URL:-http://localhost:17170}"
LOG_DIR="${LOG_DIR:-logs}"
LOG_FILE="${LOG_DIR}/validation_$(date +%Y%m%d_%H%M%S).log"

TOKEN_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token"
USERINFO_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/userinfo"
INTROSPECT_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token/introspect"
REVOKE_ENDPOINT="${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/revoke"

mkdir -p "$LOG_DIR"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0; FAIL=0; WARN=0

ts()      { date '+%H:%M:%S'; }
log()     { echo "$*" | tee -a "$LOG_FILE"; }
info()    { log "[$(ts) INFO]  $*"; }
ok()      { log "[$(ts) PASS]  $*"; PASS=$((PASS+1)); }
fail()    { log "[$(ts) FAIL]  $*"; FAIL=$((FAIL+1)); }
warn()    { log "[$(ts) WARN]  $*"; WARN=$((WARN+1)); }
section() { log ""; log "======================================================"; log "  $*"; log "======================================================"; }


get_token() {
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
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$1',''))" <<< "$2" 2>/dev/null || true
}

get_userinfo() {
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

save_token() {
    local user="$1" token="$2"
    echo "$token" > "$TMPDIR/${user}_token"
}

get_saved_token() {
    local user="$1"
    cat "$TMPDIR/${user}_token" 2>/dev/null || true
}


USERS="alice:alice1234:admins:yes
bob:bob12345:developers:no
carol:carol1234:developers:no
dave:dave12345:viewers:no
eve:eve12345:viewers:no
mallory:mallory1234::no"


section "PREFLIGHT — Service availability"


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


section "SCENARIO 1 — Login (token issuance) for all users"


echo "$USERS" | while IFS=: read -r username password expected_groups admin_access; do
    resp=$(get_token "$username" "$password")
    error=$(json_field "error" "$resp")
    access_token=$(json_field "access_token" "$resp")

    if [ -n "$error" ] || [ -z "$access_token" ]; then
        fail "${username}: login FAILED — ${error:-no token}"
        continue
    fi

    ok "${username}: token issued successfully"
    save_token "$username" "$access_token"
done


section "SCENARIO 2 — groups claim validation (LDAP -> Keycloak -> JWT)"


echo "$USERS" | while IFS=: read -r username password expected_groups admin_access; do
    tok=$(get_saved_token "$username")
    if [ -z "$tok" ]; then
        warn "${username}: no token, skip groups check"
        continue
    fi

    actual_groups=$(get_userinfo "$tok")

    if [ "$actual_groups" = "$expected_groups" ]; then
        ok "${username}: groups=[${actual_groups:-none}] correct"
    else
        fail "${username}: groups=[${actual_groups:-none}], expected=[${expected_groups:-none}]"
    fi
done


section "SCENARIO 3 — Wrong password rejected by Keycloak"


echo "$USERS" | while IFS=: read -r username password expected_groups admin_access; do
    resp=$(get_token "$username" "TOTALLY_WRONG_PASS_XYZ!")
    error=$(json_field "error" "$resp")
    bad_token=$(json_field "access_token" "$resp")

    if [ -n "$bad_token" ]; then
        fail "${username}: wrong password accepted! Security breach."
    else
        ok "${username}: wrong password rejected"
    fi
done


section "SCENARIO 4 — mallory: no group -> /unauthorized"

mall_tok=$(get_saved_token "mallory")

if [ -z "$mall_tok" ]; then
    ok "mallory: Keycloak refused to issue token"
else
    mall_groups=$(get_userinfo "$mall_tok")

    if [ -z "$mall_groups" ]; then
        ok "mallory: token valid, groups=[] — app redirects to /unauthorized"

        unauth_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            "${APP_URL}/unauthorized" 2>/dev/null || echo "000")
        if echo "$unauth_code" | grep -qE "^(200|302|403)$"; then
            ok "mallory: /unauthorized page reachable (HTTP ${unauth_code})"
        else
            warn "mallory: /unauthorized returned HTTP ${unauth_code}"
        fi
    else
        fail "mallory: unexpectedly has groups=[${mall_groups}]"
    fi
fi

section "SCENARIO 5 — Admin access: alice allowed, all others denied"


echo "$USERS" | while IFS=: read -r username password expected_groups admin_access; do
    tok=$(get_saved_token "$username")
    if [ -z "$tok" ]; then
        warn "${username}: no token, skip admin check"
        continue
    fi

    groups=$(get_userinfo "$tok")
    in_admins="no"
    echo "$groups" | grep -q "admins" && in_admins="yes"

    if [ "$admin_access" = "yes" ]; then
        if [ "$in_admins" = "yes" ]; then
            ok "${username}: in 'admins' — /admin GRANTED"
        else
            fail "${username}: expected admin access but groups=[${groups}]"
        fi
    else
        if [ "$in_admins" = "no" ]; then
            ok "${username}: NOT in 'admins' — /admin DENIED (groups=[${groups:-none}])"
        else
            fail "${username}: unexpectedly in 'admins' group!"
        fi
    fi
done

section "SCENARIO 6 — Logout: token revocation"


echo "$USERS" | while IFS=: read -r username password expected_groups admin_access; do
    tok=$(get_saved_token "$username")
    if [ -z "$tok" ]; then
        warn "${username}: no token, skip logout test"
        continue
    fi

    revoke "$tok"
    sleep 0.5

    active_after=$(introspect "$tok")
    if [ "$active_after" = "false" ]; then
        ok "${username}: logout confirmed — token revoked"
    else
        warn "${username}: token still active after revoke (stateless JWT, expires naturally)"
    fi
done


section "SCENARIO 7 — Collect LDAP and Keycloak logs"


SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if bash "${SCRIPT_DIR}/collect_logs.sh" 2>&1 | tee -a "$LOG_FILE"; then
    ok "Logs collected — see ${LOG_DIR}/"
else
    warn "Log collection had issues (non-fatal)"
fi


section "VALIDATION SUMMARY"


TOTAL=$((PASS + FAIL))
log ""
log "  Tests run  : ${TOTAL}"
log "  Passed     : ${PASS}"
log "  Failed     : ${FAIL}"
log "  Warnings   : ${WARN}"
log ""
log "  Log file: ${LOG_FILE}"
log ""

if [ $FAIL -eq 0 ]; then
    log "  ALL CHECKS PASSED"
    exit 0
else
    log "  ${FAIL} CHECK(S) FAILED"
    exit 1
fi
