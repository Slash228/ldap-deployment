#!/bin/bash
set -e

LLDAP_URL="http://localhost:17170"
LDAP_URL="ldap://localhost:3890"
ADMIN_USER="admin"
ADMIN_PASS="changeme_strong_password"
BASE_DN="dc=dnp,dc=local"
ADMIN_DN="uid=admin,ou=people,$BASE_DN"

echo "==> Logging in to LLDAP..."
TOKEN=$(curl -s "$LLDAP_URL/auth/simple/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
  echo "ERROR: Failed to get token. Is LLDAP running?"
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
echo "==> Done! Created 3 groups and 6 users."
echo ""
echo "    Credentials:"
echo "    alice   / alice1234    (admins)"
echo "    bob     / bob12345     (developers)"
echo "    carol   / carol1234   (developers)"
echo "    dave    / dave12345    (viewers)"
echo "    eve     / eve12345     (viewers)"
echo "    mallory / mallory1234  (no group)"
