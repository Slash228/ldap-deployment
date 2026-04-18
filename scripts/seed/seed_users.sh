#!/bin/bash
set -e

LLDAP_URL="http://localhost:17170"
ADMIN_USER="admin"
ADMIN_PASS="changeme_strong_password"

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
  # Set password
  gql "mutation { updateUser(user: { id: \\\"$uid\\\", password: \\\"$pass\\\" }) { ok } }" > /dev/null
}

add_to_group() {
  local uid=$1 group=$2
  echo "  Adding $uid -> $group"
  local gid=$(gql "{ group(name: \\\"$group\\\") { id } }" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  if [ -z "$gid" ]; then
    echo "  WARNING: group $group not found"
    return
  fi
  gql "mutation { addUserToGroup(userId: \\\"$uid\\\", groupId: $gid) { ok } }" > /dev/null
}

# ── Groups ──
echo "==> Creating groups..."
create_group "admins"
create_group "developers"
create_group "viewers"

# ── Users ──
echo "==> Creating users..."
create_user "alice"   "alice@dnp.local"   "Alice Smith"   "Alice"   "Smith"   "alice123"
create_user "bob"     "bob@dnp.local"     "Bob Jones"     "Bob"     "Jones"   "bob123"
create_user "carol"   "carol@dnp.local"   "Carol Davis"   "Carol"   "Davis"   "carol123"
create_user "dave"    "dave@dnp.local"    "Dave Wilson"   "Dave"    "Wilson"  "dave123"
create_user "eve"     "eve@dnp.local"     "Eve Brown"     "Eve"     "Brown"   "eve123"
create_user "mallory" "mallory@dnp.local" "Mallory Black" "Mallory" "Black"   "mallory123"

# ── Assign groups ──
echo "==> Assigning groups..."
add_to_group "alice" "admins"
add_to_group "bob"   "developers"
add_to_group "carol" "developers"
add_to_group "dave"  "viewers"
add_to_group "eve"   "viewers"
# mallory — no group (intentional, for testing access denial)

echo ""
echo "==> Done! Created 3 groups and 6 users."
echo "    admins:     alice"
echo "    developers: bob, carol"
echo "    viewers:    dave, eve"
echo "    no group:   mallory"
