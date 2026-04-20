#!/bin/bash
cd "$(dirname "$0")"
echo "==> Stopping..."
docker compose -f docker/docker-compose.yml --env-file .env down
echo "==> Done"
