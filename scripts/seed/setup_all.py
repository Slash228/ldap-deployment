#!/usr/bin/env python3
"""Create LLDAP users, groups, passwords. Then sync Keycloak."""
import requests, json, sys, time, os

LLDAP_URL = "http://localhost:17170"
LDAP_HOST = "localhost"
LDAP_PORT = 3890
KEYCLOAK_URL = "http://localhost:8080"
REALM = "dnp-realm"
BASE_DN = "dc=dnp,dc=local"

# Read .env
env_path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), ".env")
env = {}
if os.path.exists(env_path):
    with open(env_path) as f:
        for line in f:
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                env[k] = v

LLDAP_PASS = env.get("LLDAP_ADMIN_PASSWORD", "changeme_strong_password")
KC_ADMIN = env.get("KEYCLOAK_ADMIN", "admin")
KC_PASS = env.get("KEYCLOAK_ADMIN_PASSWORD", "changeme_admin_pass")

print("=" * 50)
print("SETUP: LLDAP users + Keycloak sync")
print("=" * 50)

# ── LLDAP Login ──
print("\n[1] LLDAP login...")
token = None
for i in range(30):
    try:
        r = requests.post(f"{LLDAP_URL}/auth/simple/login",
            json={"username": "admin", "password": LLDAP_PASS})
        token = r.json()["token"]
        print("   OK")
        break
    except:
        time.sleep(1)
if not token:
    print("   FAILED")
    sys.exit(1)

def gql(query):
    r = requests.post(f"{LLDAP_URL}/api/graphql",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={"query": query})
    return r.json()

# ── Groups ──
print("\n[2] Creating groups...")
for g in ["admins", "developers", "viewers"]:
    r = gql(f'mutation {{ createGroup(name: "{g}") {{ id }} }}')
    if r and r.get("data", {}).get("createGroup"):
        print(f"   {g}: created")
    elif r and "UNIQUE" in str(r):
        print(f"   {g}: exists")

r = gql("{ groups { id displayName } }")
groups = {}
if r and r.get("data"):
    groups = {g["displayName"]: g["id"] for g in r["data"].get("groups", [])}
print(f"   IDs: {groups}")

# ── Users ──
users = [
    ("alice", "alice@dnp.local", "Alice Smith", "Alice", "Smith", "alice1234", "admins"),
    ("bob", "bob@dnp.local", "Bob Jones", "Bob", "Jones", "bob12345", "developers"),
    ("carol", "carol@dnp.local", "Carol Davis", "Carol", "Davis", "carol1234", "developers"),
    ("dave", "dave@dnp.local", "Dave Wilson", "Dave", "Wilson", "dave12345", "viewers"),
    ("eve", "eve@dnp.local", "Eve Brown", "Eve", "Brown", "eve12345", "viewers"),
    ("mallory", "mallory@dnp.local", "Mallory Black", "Mallory", "Black", "mallory1234", None),
]

print("\n[3] Creating users...")
for uid, email, display, first, last, pwd, gname in users:
    print(f"\n   {uid}:")
    
    # Create via GraphQL
    r = gql(f'mutation {{ createUser(user: {{ id: "{uid}", email: "{email}", displayName: "{display}", firstName: "{first}", lastName: "{last}" }}) {{ id }} }}')
    if r and r.get("data", {}).get("createUser"):
        print("      created")
    elif r and "UNIQUE" in str(r):
        print("      exists")
    else:
        print("      exists" if (r and "UNIQUE" in str(r)) else "error")

    # Set password via LDAP extended operation
    try:
        from ldap3 import Connection, Server
        server = Server(LDAP_HOST, port=LDAP_PORT)
        conn = Connection(server, f"uid=admin,ou=people,{BASE_DN}", LLDAP_PASS, auto_bind=True)
        conn.extend.standard.modify_password(
            user=f"uid={uid},ou=people,{BASE_DN}",
            new_password=pwd
        )
        print(f"      password: {conn.result['description']}")
    except ImportError:
        print("      ERROR: ldap3 not installed. Run: sudo pacman -S python-ldap3")
        sys.exit(1)
    except Exception as e:
        print(f"      password error: {e}")

    # Add to group
    if gname and gname in groups:
        r = gql(f'mutation {{ addUserToGroup(userId: "{uid}", groupId: {groups[gname]}) {{ ok }} }}')
        ok = False
        if r and r.get("data") and r["data"].get("addUserToGroup"):
            ok = r["data"]["addUserToGroup"].get("ok", False)
        print(f"      group {gname}: {'OK' if ok else 'failed'}")

# ── Verify ──
print("\n[4] LLDAP users:")
r = gql("{ users { id displayName groups { displayName } } }")
if r and r.get("data"):
    for u in r["data"].get("users", []):
        gs = ", ".join(g["displayName"] for g in u.get("groups", [])) or "no groups"
        print(f"   {u['id']}: {gs}")

# ── Keycloak sync ──
print("\n[5] Keycloak sync...")
kc_token = None
for i in range(30):
    try:
        r = requests.post(f"{KEYCLOAK_URL}/realms/master/protocol/openid-connect/token",
            data={"grant_type": "password", "client_id": "admin-cli", "username": KC_ADMIN, "password": KC_PASS})
        kc_token = r.json()["access_token"]
        print("   login OK")
        break
    except:
        time.sleep(1)

if not kc_token:
    print("   FAILED")
    sys.exit(1)

try:
    r = requests.get(f"{KEYCLOAK_URL}/admin/realms/{REALM}/components?type=org.keycloak.storage.UserStorageProvider",
        headers={"Authorization": f"Bearer {kc_token}"})
    provider_id = [c for c in r.json() if c.get("name") == "lldap-provider"][0]["id"]

    r = requests.post(f"{KEYCLOAK_URL}/admin/realms/{REALM}/user-storage/{provider_id}/sync?action=triggerFullSync",
        headers={"Authorization": f"Bearer {kc_token}"})
    print(f"   users: {r.json()}")

    for m in requests.get(f"{KEYCLOAK_URL}/admin/realms/{REALM}/components?parent={provider_id}",
        headers={"Authorization": f"Bearer {kc_token}"}).json():
        if m.get("name") == "group-ldap-mapper":
            requests.post(f"{KEYCLOAK_URL}/admin/realms/{REALM}/user-storage/{provider_id}/mappers/{m['id']}/sync?direction=fedToKeycloak",
                headers={"Authorization": f"Bearer {kc_token}"})
            print("   groups: synced")
except Exception as e:
    print(f"   Error: {e}")

print("\n" + "=" * 50)
print("DONE! Open http://localhost:3000")
print("=" * 50)
