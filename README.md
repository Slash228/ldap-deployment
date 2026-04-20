# LDAP Deployment

Self-hosted LDAP authentication infrastructure built with LLDAP, Keycloak,
and a demo application, fully containerized via Docker Compose.

## Architecture

**Components:**
- **LLDAP** — lightweight LDAP server, source of truth for users and groups (port 3890 — LDAP, port 17170 — Web UI)
- **PostgreSQL** — database backend for Keycloak
- **Keycloak** — Identity Provider, federates users from LLDAP, issues OIDC tokens (port 8080)
- **Demo App** — web service protected via OIDC, performs RBAC based on LDAP groups (port 3000)

## Naming Schema

| Element    | Value                              |
|------------|------------------------------------|
| Base DN    | `dc=dnp,dc=local`                 |
| Users OU   | `ou=people,dc=dnp,dc=local`       |
| Groups OU  | `ou=groups,dc=dnp,dc=local`       |
| Groups     | `admins`, `developers`, `viewers`  |

## Prerequisites

- Docker Desktop (macOS/Windows) or Docker Engine (Linux)
- Docker Compose v2+
- `ldap-utils` (for manual LDAP verification)
  - macOS: `brew install openldap`
  - Ubuntu/Debian: `sudo apt install ldap-utils`

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/Slash228/ldap-deployment.git
cd ldap-deployment
cp .env.example .env
```

### 2. Start everything

```bash
./start.sh
```

This will:
- Start LLDAP, PostgreSQL, and Keycloak containers
- Wait for LLDAP to be healthy
- Run the seed script to create test users, groups, and passwords

### 3. Verify

| Service        | URL                          | Credentials                          |
|----------------|------------------------------|--------------------------------------|
| LLDAP Web UI   | http://localhost:17170       | `admin` / `changeme_strong_password` |
| Keycloak Admin | http://localhost:8080        | `admin` / `changeme_admin_pass`      |
| Demo App       | http://localhost:3000        | Any test user (see below)            |

### 4. Stop

```bash
./stop.sh        # stop containers (data preserved)
./reset.sh       # full reset: delete all data and start fresh
```

## Test Users

Created automatically by the seed script (`scripts/seed/seed_users.sh`):

| Username | Password       | Group        | Purpose                     |
|----------|----------------|--------------|-----------------------------|
| alice    | alice1234      | admins       | Full admin access           |
| bob      | bob12345       | developers   | Developer-level access      |
| carol    | carol1234      | developers   | Developer-level access      |
| dave     | dave12345      | viewers      | Read-only access            |
| eve      | eve12345       | viewers      | Read-only access            |
| mallory  | mallory1234    | *(none)*     | Access denial testing       |

## Manual LDAP Verification

```bash
# Test successful login
ldapsearch -H ldap://localhost:3890 -x \
  -D "uid=alice,ou=people,dc=dnp,dc=local" -w alice1234 \
  -b "dc=dnp,dc=local" "(uid=alice)" cn mail

# Test wrong password (should return: Invalid credentials)
ldapsearch -H ldap://localhost:3890 -x \
  -D "uid=alice,ou=people,dc=dnp,dc=local" -w wrongpass \
  -b "dc=dnp,dc=local" "(uid=alice)" cn

# List all groups and members
ldapsearch -H ldap://localhost:3890 -x \
  -D "uid=admin,ou=people,dc=dnp,dc=local" -w changeme_strong_password \
  -b "ou=groups,dc=dnp,dc=local" "(objectClass=groupOfUniqueNames)" cn member
```

## Validation

See [docs/VALIDATION.md](docs/VALIDATION.md) for full details.

```bash
bash scripts/validation/smoke_test.sh          # quick check
/opt/homebrew/bin/bash scripts/validation/run_validation.sh  # full suite
```

Results: **35/35 checks passed**

| Scenario | Coverage |
|----------|----------|
| Login/logout for 6 users | ✅ |
| Wrong password rejection | ✅ |
| mallory → /unauthorized (no group) | ✅ |
| /admin → admins only | ✅ |
| Token revocation on logout | ✅ |
| LDAP + Keycloak logs | ✅ |

## Project Structure

```text
.
├── start.sh                # Start all services + seed data
├── stop.sh                 # Stop all services (data preserved)
├── reset.sh                # Full reset and fresh start
├── .env.example            # Environment variables template
├── docker/
│   ├── docker-compose.yml  # All services: LLDAP, PostgreSQL, Keycloak
│   └── keycloak/
│       └── realm-export.json  # Keycloak realm with LDAP federation
├── scripts/
│   ├── seed/
│   │   └── seed_users.sh   # Creates test users, passwords, and groups
│   └── validation/         # Automated validation scenarios
├── docs/
│   ├── diagrams/           # Architecture diagrams
│   └── screenshots/        # Screenshots for report
├── report/                 # IMRaD report sources and PDF
└── logs/examples/          # Captured logs for report
```

## License

MIT
