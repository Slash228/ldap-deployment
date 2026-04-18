# LDAP Deployment

Self-hosted LDAP authentication infrastructure built with LLDAP, Keycloak,
and a demo application, fully containerized via Docker Compose.

## Architecture


**Components:**
- **LLDAP** — lightweight LDAP server, source of truth for users and groups
- **Keycloak** — Identity Provider, federates users from LLDAP, issues OIDC tokens
- **Demo app** — web service protected via OIDC, performs RBAC based on LDAP groups

## Naming Schema

| Element    | Value                              |
|------------|------------------------------------|
| Base DN    | `dc=dnp,dc=local`                 |
| Users OU   | `ou=people,dc=dnp,dc=local`       |
| Groups OU  | `ou=groups,dc=dnp,dc=local`       |
| Groups     | `admins`, `developers`, `viewers`  |

## Quick Start

```bash
cp .env.example .env
# edit .env — replace all "changeme" / "replace_with_..." values
docker compose up -d
```

## Project Structure
```text
.
├── docker/                 # docker-compose and per-service configs
├── scripts/
│   ├── seed/               # user/group provisioning scripts
│   └── validation/         # automated validation scenarios
├── docs/                   # diagrams and screenshots
├── report/                 # IMRaD report sources and PDF
└── logs/examples/          # captured logs for the report
```
## License

MIT
