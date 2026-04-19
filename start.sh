#!/bin/bash
cd "$(dirname "$0")"
docker compose -f docker/docker-compose.yml --env-file .env up -d

echo "==> Waiting for LLDAP to be ready..."
until curl -sf http://localhost:17170/health > /dev/null 2>&1; do
  sleep 2
done
echo "==> LLDAP is ready"

echo "==> Running seed script..."
bash scripts/seed/seed_users.sh
