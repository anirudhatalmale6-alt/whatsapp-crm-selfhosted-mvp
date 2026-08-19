#!/usr/bin/env bash
# Copia diaria: las 3 bases de datos + las credenciales de sesion de cada
# numero. Con esto se puede reconstruir el servidor entero sin volver a
# escanear los QR. Ponerlo en cron:  0 3 * * * /ruta/scripts/backup.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

DEST="${BACKUP_DIR:-./backups}"
STAMP=$(date +%Y%m%d-%H%M)
KEEP="${BACKUP_KEEP_DAYS:-14}"
mkdir -p "$DEST"

for db in evolution_n1 evolution_n2 chatwoot; do
  docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$db" \
    | gzip > "$DEST/${db}-${STAMP}.sql.gz"
  echo "ok  $DEST/${db}-${STAMP}.sql.gz"
done

for v in evo_n1_instances evo_n2_instances chatwoot_storage; do
  docker run --rm -v "wacrm_${v}:/data:ro" -v "$(pwd)/${DEST#./}:/out" \
    alpine tar czf "/out/${v}-${STAMP}.tar.gz" -C /data .
  echo "ok  $DEST/${v}-${STAMP}.tar.gz"
done

find "$DEST" -name '*.gz' -mtime "+${KEEP}" -delete
echo "copia terminada: $STAMP"
