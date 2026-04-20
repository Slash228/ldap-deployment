import os

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://localhost:8080")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "dnp-realm")
KEYCLOAK_CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "demo-app")
KEYCLOAK_CLIENT_SECRET = os.environ.get("KEYCLOAK_CLIENT_SECRET", "demo-app-secret")
APP_URL = os.environ.get("APP_URL", "http://localhost:3000")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "changeme_session_secret")

ISSUER_URL = f"{KEYCLOAK_URL}/realms/{KEYCLOAK_REALM}"
END_SESSION_URL = f"{ISSUER_URL}/protocol/openid-connect/logout"

GROUP_ROLE_MAP = {
    "admins": "admin",
    "developers": "dashboard",
    "viewers": "public",
}
