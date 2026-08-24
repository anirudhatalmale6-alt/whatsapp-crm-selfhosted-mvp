#!/usr/bin/env bash
# =============================================================================
#  Copia de seguridad diaria del CRM.
#
#  Guarda:
#    - las 3 bases de datos (chatwoot + una por numero)
#    - los volumenes de datos y los adjuntos de Chatwoot
#    - la configuracion (.env, .env.chatwoot, docker-compose.yml)
#
#  ⚠️ Las credenciales de sesion de WhatsApp viven en la tabla "Session" de
#  cada base evolution_nX, NO en el volumen (el volumen tiene 8 KB). Por eso
#  el pg_dump es lo que de verdad evita tener que reescanear los QR.
#
#  Si algo falla, avisa por Telegram. Una copia que falla en silencio es peor
#  que no tener copia, porque crees que estas protegido.
#
#  En cron:   0 3 * * *  /opt/wacrm/scripts/backup.sh >> /var/log/wacrm-backup.log 2>&1
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
BASE="$(pwd)"
set -a; source .env; set +a

DEST="${BACKUP_DIR:-$BASE/backups}"
STAMP=$(date +%Y%m%d-%H%M)
KEEP="${BACKUP_KEEP_DAYS:-14}"
mkdir -p "$DEST"

FALLOS=()
log() { echo "[$(date +%H:%M:%S)] $*"; }

avisar_fallo() {
  texto="$1"
  echo "$texto"
  esc=$(printf '%s' "$texto" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  if [ -n "${ALERT_TELEGRAM_TOKEN:-}" ] && [ -n "${ALERT_TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -m 20 -H 'Content-Type: application/json' \
      -d "{\"chat_id\":\"$ALERT_TELEGRAM_CHAT_ID\",\"text\":\"$esc\"}" \
      "https://api.telegram.org/bot$ALERT_TELEGRAM_TOKEN/sendMessage" >/dev/null 2>&1 || true
  fi
  if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
    curl -s -m 20 -H 'Content-Type: application/json' \
      -d "{\"text\":\"$esc\",\"content\":\"$esc\",\"message\":\"$esc\"}" \
      "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}

# --- bases de datos ----------------------------------------------------------
# Se vuelca a un temporal y solo se renombra si el volcado esta COMPLETO.
# Asi nunca queda en la carpeta una copia a medias que parezca buena.
for db in chatwoot evolution_n1 evolution_n2; do
  tmp="$DEST/.${db}-${STAMP}.sql.gz.parcial"
  final="$DEST/${db}-${STAMP}.sql.gz"

  if ! docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wacrm-postgres-1 \
        pg_dump -U "$POSTGRES_USER" "$db" 2>/dev/null | gzip > "$tmp"; then
    FALLOS+=("$db: fallo el pg_dump")
    rm -f "$tmp"; continue
  fi

  if ! gzip -t "$tmp" 2>/dev/null; then
    FALLOS+=("$db: el fichero comprimido esta corrupto")
    rm -f "$tmp"; continue
  fi

  # pg_dump escribe esta linea al final. Si no esta, el volcado se corto.
  if ! zcat "$tmp" | tail -5 | grep -q "PostgreSQL database dump complete"; then
    FALLOS+=("$db: el volcado esta incompleto (cortado a medias)")
    rm -f "$tmp"; continue
  fi

  mv "$tmp" "$final"
  log "ok  $(basename "$final")  $(du -h "$final" | cut -f1)"
done

# --- volumenes ---------------------------------------------------------------
for v in evo_n1_instances evo_n2_instances chatwoot_storage; do
  final="$DEST/${v}-${STAMP}.tar.gz"
  if docker run --rm -v "wacrm_${v}:/data:ro" -v "$DEST:/out" \
       alpine tar czf "/out/${v}-${STAMP}.tar.gz" -C /data . 2>/dev/null \
     && gzip -t "$final" 2>/dev/null; then
    log "ok  $(basename "$final")  $(du -h "$final" | cut -f1)"
  else
    FALLOS+=("volumen $v: no se pudo copiar")
    rm -f "$final"
  fi
done

# --- configuracion -----------------------------------------------------------
# Sin esto no se puede reconstruir el servidor: lleva las claves de API, las
# del proxy y las de la base de datos.
final="$DEST/config-${STAMP}.tar.gz"
if tar czf "$final" -C "$BASE" .env .env.chatwoot docker-compose.yml 2>/dev/null \
   && gzip -t "$final" 2>/dev/null; then
  chmod 600 "$final"
  log "ok  $(basename "$final")  $(du -h "$final" | cut -f1)"
else
  # Igual que arriba: si sale mal NO se deja el fichero. Un tar de 45 bytes en
  # la carpeta parece una copia buena hasta el dia que hace falta.
  rm -f "$final"
  FALLOS+=("configuracion: no se pudo copiar")
fi

# --- rotacion ----------------------------------------------------------------
borrados=$(find "$DEST" -name '*.gz' -mtime "+${KEEP}" -print -delete 2>/dev/null | wc -l)
[ "$borrados" -gt 0 ] && log "rotacion: $borrados copias de mas de $KEEP dias borradas"
find "$DEST" -name '*.parcial' -mmin +120 -delete 2>/dev/null || true

# --- resultado ---------------------------------------------------------------
libre=$(df -h "$DEST" | tail -1 | awk '{print $4}')
if [ ${#FALLOS[@]} -gt 0 ]; then
  avisar_fallo "URGENTE: la copia de seguridad del CRM ha fallado ($STAMP). Problemas: ${FALLOS[*]}. Revisar el servidor."
  exit 1
fi
log "copia completa $STAMP — $(ls -1 "$DEST"/*-"$STAMP".* 2>/dev/null | wc -l) ficheros, $(du -sh "$DEST" | cut -f1) en total, $libre libres en disco"
