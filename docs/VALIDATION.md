# Validation Guide

## Quick Start

```bash
# 1. Start the stack
./start.sh

# 2. Smoke test (5 sec)
bash scripts/validation/smoke_test.sh

# 3. Full validation
bash scripts/validation/run_validation.sh
```

## Test Users

| User    | Password    | Group      | Access             |
|---------|-------------|------------|--------------------|
| alice   | alice1234   | admins     | all pages + /admin |
| bob     | bob12345    | developers | dashboard          |
| carol   | carol1234   | developers | dashboard          |
| dave    | dave12345   | viewers    | public only        |
| eve     | eve12345    | viewers    | public only        |
| mallory | mallory1234 | (none)     | /unauthorized      |

## Validation Scenarios

| # | Scenario | Result |
|---|----------|--------|
| 1 | Login for all 6 users, JWT groups claim matches LDAP | PASS 6/6 |
| 2 | groups claim: admins/developers/viewers/[] | PASS 6/6 |
| 3 | Wrong password rejected by Keycloak | PASS 6/6 |
| 4 | mallory: token issued, groups=[], app redirects to /unauthorized | PASS |
| 5 | /admin: alice allowed, all others denied | PASS 6/6 |
| 6 | Logout: token revoked, introspect active=false | PASS 6/6 |
| 7 | LDAP + Keycloak logs collected | PASS |

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

- Client secret is `demo-app-secret` (set in `docker/keycloak/realm-export.json`)
- Validation scripts require `curl` and `python3` (available on all major platforms)
- All scripts use POSIX-compatible bash (no bash 4+ features required)
