#!/usr/bin/env bash
set -euo pipefail
if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
cd /opt/formbricks
docker compose -f docker-compose.yml -f docker-compose.override.yml config >/dev/null
docker compose -f docker-compose.yml -f docker-compose.override.yml pull
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d --force-recreate
sleep 3
bash -c 'for i in {1..90}; do code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || true); [ "$code" != "000" ] && { echo "HTTP $code"; exit 0; }; sleep 2; done; echo "timeout"; exit 1'
sudo nginx -t && sudo systemctl reload nginx
echo "OK"
