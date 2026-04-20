
# Validation Guide

## Quick Start

```bash
# 1. Start the stack
./start.sh

# 2. Smoke test (5 sec)
bash scripts/validation/smoke_test.sh

# 3. Full validation
/opt/homebrew/bin/bash scripts/validation/run_validation.sh
```

## Test Users

| User    | Password     | Group      | Access          |
|---------|-------------|------------|-----------------|
| alice   | alice1234   | admins     | all pages + /admin |
| bob     | bob12345    | developers | dashboard       |
| carol   | carol1234   | developers | dashboard       |
| dave    | dave12345   | viewers    | public only     |
| eve     | eve12345    | viewers    | public only     |
| mallory | mallory1234 | —          | /unauthorized   |

## Validation Scenarios

| # | Scenario | Result |
|---|----------|--------|
| 1 | Login for all 6 users, JWT groups claim matches LDAP | ✅ 6/6 |
| 2 | groups claim: admins/developers/viewers/[] | ✅ 6/6 |
| 3 | Wrong password rejected by Keycloak | ✅ 6/6 |
| 4 | mallory: token issued, groups=[], app → /unauthorized | ✅ |
| 5 | /admin: alice allowed, all others denied | ✅ 6/6 |
| 6 | Logout: token revoked, introspect active=false | ✅ 6/6 |
| 7 | LDAP + Keycloak logs collected | ✅ |

**Total: 35/35 PASSED**

## Log Files

| File | Contents |
|------|----------|
| `logs/examples/lldap_parsed.log` | LDAP BIND/SEARCH operations |
| `logs/examples/lldap_raw.log` | Raw LLDAP container output |
| `logs/examples/keycloak_events.json` | LOGIN/LOGOUT/LOGIN_ERROR events |
| `logs/examples/keycloak_raw.log` | Raw Keycloak container output |
| `logs/examples/validation_sample.log` | Full validation run output |

## Notes

- macOS ships with bash 3.2 — use `brew install bash` and run with `/opt/homebrew/bin/bash`
- Keycloak 26 requires HTTPS for master realm from outside — `setup_keycloak.sh` uses `kcadm.sh` via `docker exec`
- Client secret is `demo-app-secret` (hardcoded in `docker/keycloak/realm-export.json`)
EOF
