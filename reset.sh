#!/bin/bash
cd "$(dirname "$0")"
echo "==> Stopping all containers..."
docker compose -f docker/docker-compose.yml --env-file .env down
echo "==> Removing LLDAP data..."
docker volume rm docker_lldap-data 2>/dev/null || true
echo "==> Starting fresh..."
./start.sh
