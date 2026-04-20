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
KCADM="docker exec keycloak /opt/keycloak/bin/kcadm.sh"
KCFG="--config /tmp/kcadm.config"

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
$KCADM config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KC_ADMIN" \
    --password "$KC_PASS" \
    $KCFG 2>/dev/null
echo "  OK"

echo "==> Configuring LDAP User Federation..."
REALM_ID=$($KCADM get realms/$REALM --fields id $KCFG 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Check if lldap-provider already exists
PROVIDER_ID=$($KCADM get components \
    --target-realm $REALM \
    --query "type=org.keycloak.storage.UserStorageProvider" \
    $KCFG 2>/dev/null \
    | python3 -c "
import sys,json
data=json.load(sys.stdin)
for c in data:
    if c.get('name')=='lldap-provider':
        print(c['id']); break
" 2>/dev/null || true)

if [ -z "$PROVIDER_ID" ]; then
    echo "  Creating LDAP provider..."
    $KCADM create components \
        --target-realm $REALM \
        $KCFG \
        -s name=lldap-provider \
        -s providerId=ldap \
        -s providerType=org.keycloak.storage.UserStorageProvider \
        -s parentId="$REALM_ID" \
        -s 'config.vendor=["other"]' \
        -s 'config.connectionUrl=["ldap://lldap:3890"]' \
        -s "config.bindDn=[\"uid=admin,ou=people,dc=dnp,dc=local\"]" \
        -s "config.bindCredential=[\"$LLDAP_PASS\"]" \
        -s 'config.usersDn=["ou=people,dc=dnp,dc=local"]' \
        -s 'config.usernameLDAPAttribute=["uid"]' \
        -s 'config.rdnLDAPAttribute=["uid"]' \
        -s 'config.uuidLDAPAttribute=["uid"]' \
        -s 'config.userObjectClasses=["inetOrgPerson"]' \
        -s 'config.editMode=["READ_ONLY"]' \
        -s 'config.importEnabled=["true"]' \
        -s 'config.syncRegistrations=["false"]' \
        -s 'config.searchScope=["2"]' \
        -s 'config.pagination=["true"]' \
        2>/dev/null

    PROVIDER_ID=$($KCADM get components \
        --target-realm $REALM \
        --query "type=org.keycloak.storage.UserStorageProvider" \
        $KCFG 2>/dev/null \
        | python3 -c "
import sys,json
data=json.load(sys.stdin)
for c in data:
    if c.get('name')=='lldap-provider':
        print(c['id']); break
")
else
    echo "  LDAP provider exists: ${PROVIDER_ID:0:8}..."
fi

echo "  Provider ID: ${PROVIDER_ID:0:8}..."

echo "==> Checking LDAP mappers..."
MAPPERS=$($KCADM get components \
    --target-realm $REALM \
    --query "parent=$PROVIDER_ID" \
    $KCFG 2>/dev/null)

create_mapper() {
    local name=$1 pid=$2 ptype=$3
    shift 3
    if echo "$MAPPERS" | python3 -c "
import sys,json
data=json.load(sys.stdin)
names=[c.get('name') for c in data]
exit(0 if '$name' in names else 1)
" 2>/dev/null; then
        echo "  Mapper '$name' exists"
        return
    fi
    echo "  Creating mapper: $name"
    $KCADM create components \
        --target-realm $REALM \
        $KCFG \
        -s "name=$name" \
        -s "providerId=$pid" \
        -s "providerType=$ptype" \
        -s "parentId=$PROVIDER_ID" \
        "$@" 2>/dev/null
}

create_mapper "username" "user-attribute-ldap-mapper" \
    "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
    -s 'config.ldap.attribute=["uid"]' \
    -s 'config.user.model.attribute=["username"]' \
    -s 'config.is.mandatory.in.ldap=["true"]' \
    -s 'config.read.only=["true"]'

create_mapper "email" "user-attribute-ldap-mapper" \
    "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
    -s 'config.ldap.attribute=["mail"]' \
    -s 'config.user.model.attribute=["email"]' \
    -s 'config.is.mandatory.in.ldap=["false"]' \
    -s 'config.read.only=["true"]'

create_mapper "first name" "user-attribute-ldap-mapper" \
    "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
    -s 'config.ldap.attribute=["givenName"]' \
    -s 'config.user.model.attribute=["firstName"]' \
    -s 'config.is.mandatory.in.ldap=["false"]' \
    -s 'config.read.only=["true"]'

create_mapper "last name" "user-attribute-ldap-mapper" \
    "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
    -s 'config.ldap.attribute=["sn"]' \
    -s 'config.user.model.attribute=["lastName"]' \
    -s 'config.is.mandatory.in.ldap=["false"]' \
    -s 'config.read.only=["true"]'

create_mapper "group-ldap-mapper" "group-ldap-mapper" \
    "org.keycloak.storage.ldap.mappers.LDAPStorageMapper" \
    -s 'config.groups.dn=["ou=groups,dc=dnp,dc=local"]' \
    -s 'config.group.name.ldap.attribute=["cn"]' \
    -s 'config.group.object.classes=["groupOfUniqueNames"]' \
    -s 'config.preserve.group.inheritance=["false"]' \
    -s 'config.ignore.missing.groups=["false"]' \
    -s 'config.membership.ldap.attribute=["member"]' \
    -s 'config.membership.attribute.type=["DN"]' \
    -s 'config.membership.user.ldap.attribute=["uid"]' \
    -s 'config.mode=["READ_ONLY"]' \
    -s 'config.user.roles.retrieve.strategy=["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"]'

echo "==> Checking groups claim mapper on demo-app client..."
CLIENT_ID=$($KCADM get clients \
    --target-realm $REALM \
    --query "clientId=demo-app" \
    $KCFG 2>/dev/null \
    | python3 -c "
import sys,json
data=json.load(sys.stdin)
print(data[0]['id']) if data else print('')
" 2>/dev/null || true)

if [ -n "$CLIENT_ID" ]; then
    PMAPPERS=$($KCADM get clients/$CLIENT_ID/protocol-mappers/models \
        --target-realm $REALM \
        $KCFG 2>/dev/null)

    if ! echo "$PMAPPERS" | python3 -c "
import sys,json
data=json.load(sys.stdin)
names=[c.get('name') for c in data]
exit(0 if 'group-membership-mapper' in names else 1)
" 2>/dev/null; then
        echo "  Adding groups claim mapper..."
        $KCADM create clients/$CLIENT_ID/protocol-mappers/models \
            --target-realm $REALM \
            $KCFG \
            -s name=group-membership-mapper \
            -s protocol=openid-connect \
            -s protocolMapper=oidc-group-membership-mapper \
            -s 'config.full.path=false' \
            -s 'config.introspection.token.claim=true' \
            -s 'config.id.token.claim=true' \
            -s 'config.access.token.claim=true' \
            -s 'config.claim.name=groups' \
            -s 'config.userinfo.token.claim=true' \
            2>/dev/null
        echo "  Added"
    else
        echo "  Groups claim mapper exists"
    fi
fi

echo "==> Syncing users from LLDAP..."
SYNC_RESULT=$($KCADM create \
    "user-storage/$PROVIDER_ID/sync?action=triggerFullSync" \
    --target-realm $REALM \
    $KCFG 2>/dev/null || true)
echo "  Result: $SYNC_RESULT"

echo "==> Syncing groups from LLDAP..."
MAPPER_ID=$($KCADM get components \
    --target-realm $REALM \
    --query "parent=$PROVIDER_ID" \
    $KCFG 2>/dev/null \
    | python3 -c "
import sys,json
data=json.load(sys.stdin)
for m in data:
    if m.get('name')=='group-ldap-mapper':
        print(m['id']); break
" 2>/dev/null || true)

if [ -n "$MAPPER_ID" ]; then
    $KCADM create \
        "user-storage/$PROVIDER_ID/mappers/$MAPPER_ID/sync?direction=fedToKeycloak" \
        --target-realm $REALM \
        $KCFG 2>/dev/null || true
    echo "  Groups synced"
else
    echo "  WARNING: group mapper not found"
fi

echo ""
echo "========================================="
echo "  Keycloak setup complete!"
echo "========================================="
