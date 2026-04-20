#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    KC_ADMIN=$(grep '^KEYCLOAK_ADMIN=' "$ENV_FILE" | cut -d= -f2)
    KC_PASS=$(grep '^KEYCLOAK_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2)
    LLDAP_PASS=$(grep '^LLDAP_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2)
else
    echo "ERROR: .env not found"
    exit 1
fi

KEYCLOAK_URL="http://localhost:8080"
REALM="dnp-realm"

echo "==> Waiting for Keycloak..."
for i in $(seq 1 60); do
    if curl -sf "$KEYCLOAK_URL/realms/$REALM" > /dev/null 2>&1; then
        echo "  Keycloak is up!"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "ERROR: Keycloak not responding"
        exit 1
    fi
    printf "  %2d/60...\r" "$i"
    sleep 2
done

echo "==> Authenticating..."
TOKEN_JSON=$(curl -s -X POST \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=admin-cli&username=$KC_ADMIN&password=$KC_PASS")

TOKEN=$(echo "$TOKEN_JSON" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
    echo "ERROR: Invalid admin credentials"
    exit 1
fi
echo "  OK"

echo "==> Configuring LDAP User Federation..."
REALM_JSON=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM" -H "Authorization: Bearer $TOKEN")
REALM_ID=$(echo "$REALM_JSON" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

EXISTING=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "Authorization: Bearer $TOKEN")

if echo "$EXISTING" | grep -q "lldap-provider"; then
    echo "  LDAP provider exists, updating..."
    PROVIDER_ID=$(echo "$EXISTING" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for c in data:
    if c.get('name')=='lldap-provider':
        print(c['id'])
        break
")
    curl -s -X PUT "$KEYCLOAK_URL/admin/realms/$REALM/components/$PROVIDER_ID" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"id\":\"$PROVIDER_ID\",
        \"name\":\"lldap-provider\",
        \"providerId\":\"ldap\",
        \"providerType\":\"org.keycloak.storage.UserStorageProvider\",
        \"parentId\":\"$REALM_ID\",
        \"config\":{
          \"vendor\":[\"other\"],
          \"connectionUrl\":[\"ldap://lldap:3890\"],
          \"bindDn\":[\"uid=admin,ou=people,dc=dnp,dc=local\"],
          \"bindCredential\":[\"$LLDAP_PASS\"],
          \"usersDn\":[\"ou=people,dc=dnp,dc=local\"],
          \"usernameLDAPAttribute\":[\"uid\"],
          \"rdnLDAPAttribute\":[\"uid\"],
          \"uuidLDAPAttribute\":[\"uid\"],
          \"userObjectClasses\":[\"inetOrgPerson\"],
          \"editMode\":[\"READ_ONLY\"],
          \"importEnabled\":[\"true\"]
        }
      }" > /dev/null
else
    echo "  Creating LDAP provider..."
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/components" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\":\"lldap-provider\",
        \"providerId\":\"ldap\",
        \"providerType\":\"org.keycloak.storage.UserStorageProvider\",
        \"parentId\":\"$REALM_ID\",
        \"config\":{
          \"vendor\":[\"other\"],
          \"connectionUrl\":[\"ldap://lldap:3890\"],
          \"bindDn\":[\"uid=admin,ou=people,dc=dnp,dc=local\"],
          \"bindCredential\":[\"$LLDAP_PASS\"],
          \"usersDn\":[\"ou=people,dc=dnp,dc=local\"],
          \"usernameLDAPAttribute\":[\"uid\"],
          \"rdnLDAPAttribute\":[\"uid\"],
          \"uuidLDAPAttribute\":[\"uid\"],
          \"userObjectClasses\":[\"inetOrgPerson\"],
          \"editMode\":[\"READ_ONLY\"],
          \"importEnabled\":[\"true\"]
        }
      }" > /dev/null
    EXISTING=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider" \
      -H "Authorization: Bearer $TOKEN")
    PROVIDER_ID=$(echo "$EXISTING" | python3 -c "
import sys,json
data=json.load(sys.stdin)
for c in data:
    if c.get('name')=='lldap-provider':
        print(c['id'])
        break
")
fi
echo "  Provider ID: $PROVIDER_ID"

echo "==> Checking LDAP mappers..."
MAPPERS=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/components?parent=$PROVIDER_ID" \
  -H "Authorization: Bearer $TOKEN")

create_mapper() {
    local name=$1 pid=$2 ptype=$3 config=$4
    if echo "$MAPPERS" | grep -q "\"name\":\"$name\""; then
        echo "  Mapper '$name' exists"
        return
    fi
    echo "  Creating mapper: $name"
    curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/components" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"name\":\"$name\",
        \"providerId\":\"$pid\",
        \"providerType\":\"$ptype\",
        \"parentId\":\"$PROVIDER_ID\",
        \"config\":$config
      }" > /dev/null
}

create_mapper "username" "user-attribute-ldap-mapper" "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
  '{"ldap.attribute":["uid"],"user.model.attribute":["username"],"is.mandatory.in.ldap":["true"],"read.only":["true"]}'

create_mapper "email" "user-attribute-ldap-mapper" "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
  '{"ldap.attribute":["mail"],"user.model.attribute":["email"],"is.mandatory.in.ldap":["false"],"read.only":["true"]}'

create_mapper "first name" "user-attribute-ldap-mapper" "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
  '{"ldap.attribute":["givenName"],"user.model.attribute":["firstName"],"is.mandatory.in.ldap":["false"],"read.only":["true"]}'

create_mapper "last name" "user-attribute-ldap-mapper" "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
  '{"ldap.attribute":["sn"],"user.model.attribute":["lastName"],"is.mandatory.in.ldap":["false"],"read.only":["true"]}'

create_mapper "group-ldap-mapper" "group-ldap-mapper" "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
  "{
    \"groups.dn\":[\"ou=groups,dc=dnp,dc=local\"],
    \"group.name.ldap.attribute\":[\"cn\"],
    \"group.object.classes\":[\"groupOfUniqueNames\"],
    \"preserve.group.inheritance\":[\"false\"],
    \"ignore.missing.groups\":[\"false\"],
    \"membership.ldap.attribute\":[\"member\"],
    \"membership.attribute.type\":[\"DN\"],
    \"membership.user.ldap.attribute\":[\"uid\"],
    \"mode\":[\"READ_ONLY\"],
    \"user.roles.retrieve.strategy\":[\"LOAD_GROUPS_BY_MEMBER_ATTRIBUTE\"]
  }"

echo "==> Checking client protocol mapper..."
CLIENTS=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=demo-app" \
  -H "Authorization: Bearer $TOKEN")
CLIENT_ID=$(echo "$CLIENTS" | python3 -c "
import sys,json
data=json.load(sys.stdin)
print(data[0]['id']) if data else print('')
")

if [ -n "$CLIENT_ID" ]; then
    PROTOCOL_MAPPERS=$(curl -s "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_ID/protocol-mappers/models" \
      -H "Authorization: Bearer $TOKEN")
    
    if ! echo "$PROTOCOL_MAPPERS" | grep -q "group-membership-mapper"; then
        echo "  Adding groups claim..."
        curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_ID/protocol-mappers/models" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d '{
            "name":"group-membership-mapper",
            "protocol":"openid-connect",
            "protocolMapper":"oidc-group-membership-mapper",
            "config":{
              "full.path":"false",
              "introspection.token.claim":"true",
              "id.token.claim":"true",
              "access.token.claim":"true",
              "claim.name":"groups",
              "userinfo.token.claim":"true"
            }
          }' > /dev/null
        echo "  Added"
    else
        echo "  Groups claim mapper exists"
    fi
fi

echo "==> Syncing users..."
SYNC_RESULT=$(curl -s -X POST "$KEYCLOAK_URL/admin/realms/$REALM/user-storage/$PROVIDER_ID/sync?action=triggerFullSync" \
  -H "Authorization: Bearer $TOKEN")
echo "  Result: $SYNC_RESULT"

echo ""
echo "========================================="
echo "  Keycloak setup complete!"
echo "========================================="
