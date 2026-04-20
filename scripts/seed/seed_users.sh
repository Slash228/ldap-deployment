#!/bin/bash
set -e

LLDAP_URL="http://localhost:17170"
LDAP_URL="ldap://localhost:3890"
KEYCLOAK_URL="http://localhost:8080"
REALM="dnp-realm"
ADMIN_USER="admin"
ADMIN_PASS="changeme_strong_password"
BASE_DN="dc=dnp,dc=local"
ADMIN_DN="uid=admin,ou=people,$BASE_DN"

# Read Keycloak credentials from .env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
if [ -f "$ENV_FILE" ]; then
  KC_ADMIN=$(grep '^KEYCLOAK_ADMIN=' "$ENV_FILE" | cut -d= -f2)
  KC_PASS=$(grep '^KEYCLOAK_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2)
else
  KC_ADMIN="admin"
  KC_PASS="changeme_admin_pass"
fi


echo "==> Logging in to LLDAP..."
TOKEN=$(curl -s "$LLDAP_URL/auth/simple/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to get LLDAP token. Is LLDAP running?"
  exit 1
fi
echo "==> Token received"

gql() {
  curl -s "$LLDAP_URL/api/graphql" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"$1\"}"
}

create_group() {
  echo "  Creating group: $1"
  gql "mutation { createGroup(name: \\\"$1\\\") { id } }" > /dev/null
}

create_user() {
  local uid=$1 email=$2 display=$3 first=$4 last=$5 pass=$6
  echo "  Creating user: $uid"
  gql "mutation { createUser(user: { id: \\\"$uid\\\", email: \\\"$email\\\", displayName: \\\"$display\\\", firstName: \\\"$first\\\", lastName: \\\"$last\\\" }) { id } }" > /dev/null

  echo "  Setting password for: $uid"
  ldappasswd -H "$LDAP_URL" -x -D "$ADMIN_DN" -w "$ADMIN_PASS" -s "$pass" "uid=$uid,ou=people,$BASE_DN"
}

add_to_group() {
  local uid=$1 group=$2
  echo "  Adding $uid -> $group"

  local gid=$(gql "{ groups { id displayName } }" \
    | python3 -c "import sys,json; groups=json.load(sys.stdin)['data']['groups']; print(next((g['id'] for g in groups if g['displayName']=='$group'),''))")

  if [ -z "$gid" ]; then
    echo "  WARNING: group $group not found"
    return
  fi

  gql "mutation { addUserToGroup(userId: \\\"$uid\\\", groupId: $gid) { ok } }" > /dev/null
}


echo "==> Creating groups..."
create_group "admins"
create_group "developers"
create_group "viewers"


echo "==> Creating users..."
create_user "alice"   "alice@dnp.local"   "Alice Smith"   "Alice"   "Smith"   "alice1234"
create_user "bob"     "bob@dnp.local"     "Bob Jones"     "Bob"     "Jones"   "bob12345"
create_user "carol"   "carol@dnp.local"   "Carol Davis"   "Carol"   "Davis"   "carol1234"
create_user "dave"    "dave@dnp.local"    "Dave Wilson"   "Dave"    "Wilson"  "dave12345"
create_user "eve"     "eve@dnp.local"     "Eve Brown"     "Eve"     "Brown"   "eve12345"
create_user "mallory" "mallory@dnp.local" "Mallory Black" "Mallory" "Black"   "mallory1234"


echo "==> Assigning groups..."
add_to_group "alice" "admins"
add_to_group "bob"   "developers"
add_to_group "carol" "developers"
add_to_group "dave"  "viewers"
add_to_group "eve"   "viewers"


echo ""
echo "==> Syncing with Keycloak..."

KC_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=$KC_ADMIN&password=$KC_PASS" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$KC_TOKEN" ]; then
  echo "  WARNING: Could not get Keycloak token. Skipping sync."
else
  echo "  Keycloak token received"


  PROVIDER_ID=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider" \
    -H "Authorization: Bearer $KC_TOKEN" \
    | python3 -c "import sys,json; data=json.load(sys.stdin)
for c in data:
    if c.get('name')=='lldap-provider':
        print(c['id']); break" 2>/dev/null)

  if [ -z "$PROVIDER_ID" ]; then
    echo "  WARNING: LDAP provider not found in Keycloak"
  else
    echo "  Provider ID: ${PROVIDER_ID:0:8}..."

    # Sync users
    echo "  Syncing users..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/user-storage/$PROVIDER_ID/sync?action=triggerFullSync" \
      -H "Authorization: Bearer $KC_TOKEN" > /dev/null

    # Sync groups
    echo "  Syncing groups..."
    MAPPERS=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/components?parent=$PROVIDER_ID" \
      -H "Authorization: Bearer $KC_TOKEN")

    MAPPER_ID=$(echo "$MAPPERS" | python3 -c "import sys,json; data=json.load(sys.stdin)
for m in data:
    if m.get('name')=='group-ldap-mapper':
        print(m['id']); break" 2>/dev/null)

    if [ -n "$MAPPER_ID" ]; then
      curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/user-storage/$PROVIDER_ID/mappers/$MAPPER_ID/sync?direction=fedToKeycloak" \
        -H "Authorization: Bearer $KC_TOKEN" > /dev/null
      echo "  Groups synced"
    else
      echo "  WARNING: group mapper not found"
    fi
  fi
fi

echo ""
echo "==> Done! Created 3 groups and 6 users."
echo ""
echo "    Credentials:"
echo "    alice   / alice1234    (admins)"
echo "    bob     / bob12345     (developers)"
echo "    carol   / carol1234   (developers)"
echo "    dave    / dave12345    (viewers)"
echo "    eve     / eve12345     (viewers)"
echo "    mallory / mallory1234  (no group)"
