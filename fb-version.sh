# fb-version.sh
#!/usr/bin/env bash
set -euo pipefail

# Ejecuta como root si tu usuario no pertenece al grupo docker
if ! docker info >/dev/null 2>&1; then
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then exec sudo -E bash "$0" "$@"; fi
fi

cd /opt/formbricks

COMPOSE="-f docker-compose.yml -f docker-compose.override.yml"

echo "== Compose images (vista rápida) =="
if docker compose $COMPOSE config >/dev/null 2>&1; then
  docker compose $COMPOSE images || true
else
  echo "No se pudo validar docker-compose en /opt/formbricks (continuo con docker ps)..."
fi
echo

echo "== Contenedores Formbricks en ejecución =="
# Detecta contenedores cuya imagen contenga formbricks/formbricks (Docker Hub o GHCR)
mapfile -t CIDS < <(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' \
  | awk '$2 ~ /(ghcr\.io\/)?formbricks\/formbricks/ {print $1}')

if [ "${#CIDS[@]}" -eq 0 ]; then
  echo "No encontré contenedores ejecutando la imagen formbricks/formbricks."
  echo "Sugerencia: arranca la stack y vuelve a correr este script."
  exit 0
fi

for CID in "${CIDS[@]}"; do
  NAME=$(docker inspect -f '{{.Name}}' "$CID" | sed 's#^/##')
  IMG_ID=$(docker inspect -f '{{.Image}}' "$CID")

  REPO_TAGS=$(docker image inspect -f '{{json .RepoTags}}'   "$IMG_ID" 2>/dev/null || echo '[]')
  REPO_DIGS=$(docker image inspect -f '{{json .RepoDigests}}' "$IMG_ID" 2>/dev/null || echo '[]')
  CREATED=$(docker image inspect -f '{{.Created}}'            "$IMG_ID" 2>/dev/null || echo '<unknown>')

  OCI_VER=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}'   "$IMG_ID" 2>/dev/null || true)
  OCI_REV=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}'  "$IMG_ID" 2>/dev/null || true)
  OCI_SRC=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.source"}}'    "$IMG_ID" 2>/dev/null || true)

  echo "-----"
  echo "Contenedor        : $NAME"
  echo "Image ID          : $IMG_ID"
  echo "RepoTags          : $REPO_TAGS"
  echo "RepoDigests       : $REPO_DIGS"
  echo "Creado            : $CREATED"
  echo "OCI version label : ${OCI_VER:-<none>}"
  echo "VCS revision      : ${OCI_REV:-<none>}"
  echo "Source            : ${OCI_SRC:-<none>}"

  # Heurística de versión “mejor esfuerzo”
  BEST_VER="<desconocido>"
  if [ -n "${OCI_VER:-}" ]; then
    BEST_VER="$OCI_VER"
  else
    # Intenta extraer el tag del primer RepoTag, p.ej. "...formbricks:3.15.0"
    FIRST_TAG=$(printf '%s' "$REPO_TAGS" | sed -E 's/^\["?([^"]+)"?.*/\1/' 2>/dev/null || true)
    if grep -q ':' <<<"$FIRST_TAG"; then
      BEST_VER="${FIRST_TAG##*:}"
    fi
  fi
  echo "=> Versión detectada: $BEST_VER"
done
echo "-----"

if [ "${1:-}" = "--latest" ]; then
  echo
  echo "== Última release en GitHub (para comparar) =="
  LATEST=$(curl -s https://api.github.com/repos/formbricks/formbricks/releases/latest \
           | grep -Po '"tag_name":\s*"\K[^"]+' || true)
  echo "GitHub Releases (latest): ${LATEST:-<no disponible>}"
fi
