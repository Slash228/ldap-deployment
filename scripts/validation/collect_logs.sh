set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8080}"
KC_REALM="${KC_REALM:-dnp-realm}"
LOG_DIR="${LOG_DIR:-logs}"
LINES="${LINES:-1000}"

# Read KC admin creds from .env if available
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../.env"
if [[ -f "$ENV_FILE" ]]; then
    KC_ADMIN=$(grep '^KEYCLOAK_ADMIN=' "$ENV_FILE" | cut -d= -f2 || echo "admin")
    KC_PASS=$(grep '^KEYCLOAK_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2 || echo "changeme_admin_pass")
else
    KC_ADMIN="${KEYCLOAK_ADMIN:-admin}"
    KC_PASS="${KEYCLOAK_ADMIN_PASSWORD:-changeme_admin_pass}"
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
log()  { echo -e "$*"; }
ok()   { log "${GREEN}[OK]${RESET}   $*"; }
warn() { log "${YELLOW}[WARN]${RESET} $*"; }
info() { log "${CYAN}[→]${RESET}    $*"; }

mkdir -p "$LOG_DIR"

# ── 1. LLDAP container logs ────────────────────────────────────────────────────
info "Collecting LLDAP logs..."

LLDAP_CONTAINER=$(docker ps --filter "name=lldap" --format "{{.Names}}" 2>/dev/null | head -1 || true)

if [[ -n "$LLDAP_CONTAINER" ]]; then
    docker logs --tail "$LINES" "$LLDAP_CONTAINER" > "${LOG_DIR}/lldap_raw.log" 2>&1
    ok "LLDAP raw log → ${LOG_DIR}/lldap_raw.log  (container: ${LLDAP_CONTAINER})"

    # Parse LDAP operations:
    # LLDAP logs BIND attempts when Keycloak federates users:
    #   - Admin BIND: uid=admin,ou=people,dc=dnp,dc=local (federation queries)
    #   - User BIND:  uid=<username>,ou=people,dc=dnp,dc=local (authentication)
    {
        echo "# LDAP Request Log — $(date)"
        echo "# Container: ${LLDAP_CONTAINER}  (last ${LINES} lines)"
        echo ""

        echo "## BIND operations (authentication / federation bind)"
        grep -iE "(BIND|bind.*dn|ldap.*auth|authenticated)" "${LOG_DIR}/lldap_raw.log" 2>/dev/null \
            | sed 's/^/  /' || echo "  (none found)"

        echo ""
        echo "## SEARCH operations (user/group lookups by Keycloak)"
        grep -iE "(SEARCH|search.*base|searching|ldap.*search)" "${LOG_DIR}/lldap_raw.log" 2>/dev/null \
            | sed 's/^/  /' || echo "  (none found)"

        echo ""
        echo "## Errors / failed operations"
        grep -iE "(error|invalid|fail|denied|unauthorized|wrong)" "${LOG_DIR}/lldap_raw.log" 2>/dev/null \
            | grep -viE "(info|debug)" \
            | sed 's/^/  /' || echo "  (none found)"

        echo ""
        echo "## User role / group assignment entries"
        grep -iE "(group|member|role|assign)" "${LOG_DIR}/lldap_raw.log" 2>/dev/null \
            | sed 's/^/  /' || echo "  (none found)"
    } > "${LOG_DIR}/lldap_parsed.log"

    ok "LLDAP parsed log → ${LOG_DIR}/lldap_parsed.log"
else
    warn "No running LLDAP container found — skipping LLDAP logs"
fi

# ── 2. Keycloak container logs ─────────────────────────────────────────────────
info "Collecting Keycloak container logs..."

KC_CONTAINER=$(docker ps --filter "name=keycloak" --format "{{.Names}}" 2>/dev/null | head -1 || true)

if [[ -n "$KC_CONTAINER" ]]; then
    docker logs --tail "$LINES" "$KC_CONTAINER" > "${LOG_DIR}/keycloak_raw.log" 2>&1
    ok "Keycloak raw log → ${LOG_DIR}/keycloak_raw.log  (container: ${KC_CONTAINER})"
else
    warn "No running Keycloak container found — skipping Keycloak container logs"
fi

# ── 3. Keycloak Events API (LOGIN / LOGOUT / LOGIN_ERROR) ──────────────────────
info "Fetching Keycloak events via Admin API..."

# Get admin token
ADMIN_TOKEN=$(curl -sf --max-time 10 \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${KC_ADMIN}" \
    --data-urlencode "password=${KC_PASS}" \
    --data-urlencode "grant_type=password" \
    "${KC_URL}/realms/master/protocol/openid-connect/token" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null) || true

if [[ -z "$ADMIN_TOKEN" ]]; then
    warn "Could not obtain Keycloak admin token — check KC admin credentials"
    warn "  Ensure KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD are set in .env"
else
    ok "Admin token obtained"

    # Fetch user-facing events: LOGIN, LOGOUT, LOGIN_ERROR, CODE_TO_TOKEN, etc.
    EVENTS_JSON=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KC_URL}/admin/realms/${KC_REALM}/events?max=200" 2>/dev/null) || true

    if [[ -n "$EVENTS_JSON" ]] && echo "$EVENTS_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "$EVENTS_JSON" > "${LOG_DIR}/keycloak_events.json"
        ok "Events JSON → ${LOG_DIR}/keycloak_events.json"

        # Format to human-readable log
        python3 - "${LOG_DIR}/keycloak_events.json" "${LOG_DIR}/keycloak_events.log" << 'PYEOF'
import sys, json
from datetime import datetime, timezone

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    events = json.load(f)

ICONS = {
    "LOGIN":         "✓ LOGIN        ",
    "LOGOUT":        "→ LOGOUT       ",
    "LOGIN_ERROR":   "✗ LOGIN_ERROR  ",
    "CODE_TO_TOKEN": "  TOKEN        ",
    "REFRESH_TOKEN": "  REFRESH      ",
}

lines = [
    f"# Keycloak User Events — realm: dnp-realm",
    f"# Total: {len(events)} events  |  generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
    "",
    f"{'Timestamp':<25} {'Event':<22} {'User':<14} {'IP':<16} {'Error/Detail'}",
    "─" * 90,
]

for ev in sorted(events, key=lambda e: e.get("time", 0)):
    ts_ms = ev.get("time", 0)
    try:
        ts = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        ts = str(ts_ms)

    etype = ev.get("type", "UNKNOWN")
    user  = ev.get("details", {}).get("username") or ev.get("userId", "?")
    ip    = ev.get("ipAddress", "")
    err   = ev.get("error", "")
    icon  = ICONS.get(etype, f"  {etype:<13}")

    lines.append(f"{ts:<25} {icon} {user:<14} {ip:<16} {err}")

with open(dst, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"  → Formatted {len(events)} events")
PYEOF
        ok "Formatted event log → ${LOG_DIR}/keycloak_events.log"

        # Quick summary to stdout
        log ""
        log "  Event summary:"
        python3 -c "
import json, sys
with open('${LOG_DIR}/keycloak_events.json') as f:
    events = json.load(f)
from collections import Counter
counts = Counter(ev.get('type','?') for ev in events)
for k, v in sorted(counts.items(), key=lambda x: -x[1]):
    print(f'    {k:<25} {v}')
" 2>/dev/null || true
        log ""
    else
        warn "Events API returned invalid JSON or empty response"
    fi

    # Fetch admin events (user creation, role assignments, group membership changes)
    ADMIN_EVENTS=$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KC_URL}/admin/realms/${KC_REALM}/admin-events?max=100" 2>/dev/null) || true

    if [[ -n "$ADMIN_EVENTS" ]] && echo "$ADMIN_EVENTS" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        echo "$ADMIN_EVENTS" > "${LOG_DIR}/keycloak_admin_events.json"
        ok "Admin events (role/group changes) → ${LOG_DIR}/keycloak_admin_events.json"
    else
        warn "Admin events: empty or invalid response"
    fi
fi

# ── 4. Summary ─────────────────────────────────────────────────────────────────
log ""
ok "Log collection complete. Files:"
ls -lh "${LOG_DIR}"/ 2>/dev/null \
    | awk 'NR>1 {printf "    %-40s %s\n", $9, $5}' || true
