#!/usr/bin/env bash
# instala-fb.sh — Formbricks en Ubuntu 24.04 + Docker + Nginx (idempotente / autocorrectivo, con pasos claros)
# Uso:
#   sudo bash instala-fb.sh fb.urmah.ai
#   sudo bash instala-fb.sh fb.urmah.ai --cert /etc/ssl/certificados/fullchain.pem --key /etc/ssl/certificados/privkey.pem
set -u
shopt -s nocasematch

# ========== util ==========
log(){ printf "\n==== %s ====\n" "$*"; }
need(){ command -v "$1" >/dev/null 2>&1; }
port_busy(){ ss -ltnp 2>/dev/null | grep -qE "[\.:]${1}\s"; }
die(){ echo "ERROR"; exit 1; }

# auto sudo
if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi

# ========== args ==========
if [[ $# -lt 1 ]]; then
  echo "Uso: $0 <dominio> [--cert <fullchain.pem>] [--key <privkey.pem>] [--ssl-dir </etc/ssl/certificados>] [--ref <main|vX.Y.Z>] [--port <3000>] [--reconfigure]"
  exit 1
fi
DOMAIN="$1"; shift || true
CERT_PATH=""; KEY_PATH=""; SSL_DIR="/etc/ssl/certificados"; FB_REF="main"; PORT="3000"; RECONFIG="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert) CERT_PATH="${2:-}"; shift 2;;
    --key)  KEY_PATH="${2:-}"; shift 2;;
    --ssl-dir) SSL_DIR="${2:-}"; shift 2;;
    --ref) FB_REF="${2:-main}"; shift 2;;
    --port) PORT="${2:-3000}"; shift 2;;
    --reconfigure) RECONFIG="1"; shift 1;;
    *) echo "Opción desconocida: $1"; exit 1;;
  esac
done
[[ -z "${CERT_PATH}" || -z "${KEY_PATH}" ]] && { CERT_PATH="${SSL_DIR%/}/fullchain.pem"; KEY_PATH="${SSL_DIR%/}/privkey.pem"; }

# ========== const ==========
FB_DOMAIN="${DOMAIN}"
FB_URL="https://${FB_DOMAIN}"
RUN_USER="${SUDO_USER:-$USER}"
INSTALL_DIR="/opt/formbricks"
ENV_FILE="${INSTALL_DIR}/.env.install"
SITE_CONF="/etc/nginx/sites-available/formbricks-${FB_DOMAIN}.conf"
SITE_LINK="/etc/nginx/sites-enabled/formbricks-${FB_DOMAIN}.conf"

# ========== prereqs ==========
log "1/8 Prerrequisitos (Docker, Compose, Nginx)"
apt-get update -y >/dev/null 2>&1 || { mkdir -p /var/lib/apt/lists/partial; apt-get clean; apt-get update -y >/dev/null 2>&1; }
apt-get install -y ca-certificates curl gnupg lsb-release nginx >/dev/null 2>&1
if ! need docker; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y >/dev/null 2>&1
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
  systemctl enable --now docker >/dev/null 2>&1
fi
systemctl enable --now nginx >/dev/null 2>&1
groupadd docker 2>/dev/null || true
usermod -aG docker "${RUN_USER}" || true

# ========== certs ==========
log "2/8 Certificados"
mkdir -p "$(dirname "$CERT_PATH")"
[[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || die
sed -i -e 's/\r$//' -e 's/[ \t]*$//' "$CERT_PATH" "$KEY_PATH" || true
chmod 600 "$KEY_PATH"; chmod 644 "$CERT_PATH"; chown root:root "$KEY_PATH" "$CERT_PATH" || true
openssl x509 -noout -in "$CERT_PATH" >/dev/null 2>&1 || die

# ========== estado / secretos ==========
log "3/8 Estado y secretos"
mkdir -p "${INSTALL_DIR}"; cd "${INSTALL_DIR}"
chown -R "${RUN_USER}:${RUN_USER}" "${INSTALL_DIR}" || true
if [[ -f "${ENV_FILE}" && "${RECONFIG}" = "0" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  FB_PORT="${FB_PORT:-$PORT}"
  FB_DOMAIN="${FB_DOMAIN:-$DOMAIN}"
  FB_URL="https://${FB_DOMAIN}"
else
  NEXTAUTH_SECRET="$(openssl rand -hex 32)"
  ENCRYPTION_KEY="$(openssl rand -hex 32)"
  CRON_SECRET="$(openssl rand -hex 32)"
  FB_PORT="${PORT}"
  cat > "${ENV_FILE}" <<EOF
FB_DOMAIN="${FB_DOMAIN}"
FB_URL="${FB_URL}"
FB_REF="${FB_REF}"
FB_PORT="${FB_PORT}"
CERT_PATH="${CERT_PATH}"
KEY_PATH="${KEY_PATH}"
NEXTAUTH_SECRET="${NEXTAUTH_SECRET}"
ENCRYPTION_KEY="${ENCRYPTION_KEY}"
CRON_SECRET="${CRON_SECRET}"
EOF
fi

# ========== puerto ==========
log "4/8 Puerto ${FB_PORT}"
if port_busy "${FB_PORT}"; then
  docker ps --format '{{.ID}} {{.Ports}}' | awk -v p=":${FB_PORT}->" '$0 ~ p {print $1}' | xargs -r docker stop >/dev/null 2>&1 || true
  sleep 1
fi
port_busy "${FB_PORT}" && die

# ========== compose ==========
log "5/8 Docker Compose (base limpio + override)"
ts=$(date +%s); mkdir -p backup
[[ -f docker-compose.yml ]] && mv -f docker-compose.yml "backup/docker-compose.yml.$ts"
[[ -f docker-compose.override.yml ]] && mv -f docker-compose.override.yml "backup/docker-compose.override.yml.$ts"
curl -fsSL "https://raw.githubusercontent.com/formbricks/formbricks/${FB_REF}/docker/docker-compose.yml" -o docker-compose.yml
sed -i '1{/^version:/d}' docker-compose.yml || true

# override (solo formbricks) con valores expandidos
set -a; source "${ENV_FILE}"; set +a
cat > docker-compose.override.yml <<EOF
services:
  formbricks:
    restart: unless-stopped
    depends_on:
      - postgres
    ports: !override
      - "127.0.0.1:${FB_PORT}:3000"
    environment:
      WEBAPP_URL: "${FB_URL}"
      NEXTAUTH_URL: "${FB_URL}"
      NEXTAUTH_SECRET: "${NEXTAUTH_SECRET}"
      ENCRYPTION_KEY: "${ENCRYPTION_KEY}"
      CRON_SECRET: "${CRON_SECRET}"
EOF

if ! docker compose -f docker-compose.yml -f docker-compose.override.yml config >/dev/null 2>&1; then
  # fallback: quitar ports del base y usar override sin !override
  sed -i '/^ *formbricks:/,/^[^ ]/ {/^ *ports:/,/^[^ ]/d}' docker-compose.yml
  cat > docker-compose.override.yml <<EOF
services:
  formbricks:
    restart: unless-stopped
    depends_on:
      - postgres
    ports:
      - "127.0.0.1:${FB_PORT}:3000"
    environment:
      WEBAPP_URL: "${FB_URL}"
      NEXTAUTH_URL: "${FB_URL}"
      NEXTAUTH_SECRET: "${NEXTAUTH_SECRET}"
      ENCRYPTION_KEY: "${ENCRYPTION_KEY}"
      CRON_SECRET: "${CRON_SECRET}"
EOF
  docker compose -f docker-compose.yml -f docker-compose.override.yml config >/dev/null 2>&1 || die
fi

# levantar
docker compose -f docker-compose.yml -f docker-compose.override.yml pull >/dev/null 2>&1 || true
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d --force-recreate >/dev/null 2>&1 || die

# preparar DB/pgvector y restart app
for _ in $(seq 1 60); do
  docker compose -f docker-compose.yml -f docker-compose.override.yml exec -T postgres pg_isready -U postgres -h localhost -p 5432 >/dev/null 2>&1 && break
  sleep 2
done
docker compose -f docker-compose.yml -f docker-compose.override.yml exec -T postgres \
  bash -lc "psql -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname='formbricks';\" | grep -q 1 || psql -U postgres -c \"CREATE DATABASE formbricks;\"" >/dev/null 2>&1 || true
docker compose -f docker-compose.yml -f docker-compose.override.yml exec -T postgres \
  psql -U postgres -d formbricks -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1 || true
docker compose -f docker-compose.yml -f docker-compose.override.yml restart formbricks >/dev/null 2>&1 || true

# ========== nginx vhost ==========
log "6/8 Nginx vhost"
cat > "${SITE_CONF}" <<NGINX
server {
  listen 80;
  listen [::]:80;
  server_name ${FB_DOMAIN};
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${FB_DOMAIN};

  ssl_certificate     ${CERT_PATH};
  ssl_certificate_key ${KEY_PATH};

  add_header X-Frame-Options DENY;
  add_header X-Content-Type-Options nosniff;
  add_header Referrer-Policy strict-origin-when-cross-origin;

  location / {
    proxy_pass http://127.0.0.1:${FB_PORT};
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
  }
}
NGINX

ln -sf "${SITE_CONF}" "${SITE_LINK}"
rm -f /etc/nginx/sites-enabled/default || true
sed -i -e 's/\r$//' -e 's/[ \t]*$//' "$CERT_PATH" "$KEY_PATH" || true
chmod 600 "$KEY_PATH"; chmod 644 "$CERT_PATH" || true
nginx -t >/dev/null 2>&1 || die
systemctl reload nginx >/dev/null 2>&1 || die
sleep 1
ss -ltnp 2>/dev/null | grep -q ':443 ' || { systemctl restart nginx >/dev/null 2>&1 || true; sleep 1; }

# chequeo local SNI (no fatal)
curl -skI https://127.0.0.1/ -H "Host: ${FB_DOMAIN}" >/dev/null 2>&1 || true

# abrir UFW si está activo
if need ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi

# ========== espera app ==========
log "7/8 Espera de salud (hasta 180s)"
READY=0
for _ in $(seq 1 90); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${FB_PORT}/" || true)
  if [[ "$code" != "000" ]]; then READY=1; break; fi
  sleep 2
done
if [[ "$READY" -ne 1 ]]; then
  docker compose -f docker-compose.yml -f docker-compose.override.yml exec -T formbricks \
    bash -lc 'env DATABASE_URL="${MIGRATE_DATABASE_URL:-$DATABASE_URL}" node ./dist/scripts/apply-migrations.js' >/dev/null 2>&1 || true
  docker compose -f docker-compose.yml -f docker-compose.override.yml restart formbricks >/dev/null 2>&1 || true
  sleep 4
fi

# ========== resumen ==========
log "8/8 OK"
echo "URL: https://${FB_DOMAIN}"
echo "Dir: ${INSTALL_DIR}"
echo "Vhost: ${SITE_CONF}"
