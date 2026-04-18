#!/bin/bash
cd "$(dirname "$0")"
docker compose -f docker/docker-compose.yml --env-file .env up -d
