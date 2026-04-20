#!/bin/bash
cd "$(dirname "$0")"

echo "==> Starting containers..."
docker compose -f docker/docker-compose.yml --env-file .env up -d --build

echo "==> Waiting for LLDAP (up to 60s)..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:17170/health > /dev/null 2>&1; then
        echo "  LLDAP ready"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "  LLDAP timeout!"
        exit 1
    fi
    sleep 1
done

echo "==> Waiting for Keycloak (up to 120s)..."
for i in $(seq 1 120); do
    if curl -sf http://localhost:8080/realms/dnp-realm > /dev/null 2>&1; then
        echo "  Keycloak ready"
        break
    fi
    if [ $i -eq 120 ]; then
        echo "  Keycloak timeout!"
        exit 1
    fi
    sleep 1
done

echo "==> Creating users and groups..."
bash scripts/seed/seed_users.sh

echo "==> Syncing Keycloak..."
bash scripts/setup_keycloak.sh

echo ""
echo "=========================================="
echo "  DONE! Open http://localhost:3000"
echo "=========================================="
echo ""
echo "  alice   / alice1234    (admins)"
echo "  bob     / bob12345     (developers)"
echo "  carol   / carol1234   (developers)"
echo "  dave    / dave12345    (viewers)"
echo "  eve     / eve12345     (viewers)"
echo "  mallory / mallory1234  (no group)"
