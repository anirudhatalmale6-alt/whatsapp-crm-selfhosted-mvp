#!/usr/bin/env bash
# =============================================================================
#  Prueba de restauracion.
#
#  Una copia que nunca se ha restaurado no es una copia: es un fichero del que
#  te fias. Esto coge la copia MAS RECIENTE de cada base, la restaura en una
#  base TEMPORAL aparte, cuenta las filas de las tablas que importan y despues
#  borra la temporal.
#
#  ⚠️ NO toca en ningun momento las bases de produccion. Solo crea y destruye
#  bases que se llaman prueba_restauracion_*.
#
#  Ademas comprueba lo que de verdad duele perder: que en la copia viajan las
#  credenciales de sesion de WhatsApp. Si eso no esta, restaurar el servidor
#  obligaria a reescanear los dos QR.
#
#  En cron (semanal):  0 4 * * 1  /opt/wacrm/scripts/probar-restauracion.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
BASE="$(pwd)"
set -a; source .env; set +a

DEST="${BACKUP_DIR:-$BASE/backups}"
PG=wacrm-postgres-1
FALLOS=()

psql_() { docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG" psql -U "$POSTGRES_USER" "$@"; }

avisar_fallo() {
  texto="$1"
  echo "$texto"
  esc=$(printf '%s' "$texto" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  if [ -n "${ALERT_TELEGRAM_TOKEN:-}" ] && [ -n "${ALERT_TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -m 20 -H 'Content-Type: application/json' \
      -d "{\"chat_id\":\"$ALERT_TELEGRAM_CHAT_ID\",\"text\":\"$esc\"}" \
      "https://api.telegram.org/bot$ALERT_TELEGRAM_TOKEN/sendMessage" >/dev/null 2>&1 || true
  fi
}

# Que tablas miramos en cada base, y cuantas filas exigimos como minimo.
# El minimo evita el falso verde de restaurar una copia vacia sin enterarse.
comprobar() {
  case "$1" in
    chatwoot)     echo "conversations:1 messages:1 contacts:1 inboxes:2 users:1" ;;
    evolution_n1) echo "Instance:1 Session:1 Chatwoot:1 Proxy:1" ;;
    evolution_n2) echo "Instance:1 Session:1 Chatwoot:1 Proxy:1" ;;
  esac
}

for db in chatwoot evolution_n1 evolution_n2; do
  copia=$(ls -1t "$DEST/${db}"-*.sql.gz 2>/dev/null | head -1)
  if [ -z "$copia" ]; then
    FALLOS+=("$db: no hay ninguna copia que probar")
    continue
  fi

  tmpdb="prueba_restauracion_${db}"
  echo "=== $db  <-  $(basename "$copia") ==="

  psql_ -d postgres -q -c "DROP DATABASE IF EXISTS \"$tmpdb\";" >/dev/null 2>&1
  if ! psql_ -d postgres -q -c "CREATE DATABASE \"$tmpdb\";" >/dev/null 2>&1; then
    FALLOS+=("$db: no se pudo crear la base temporal")
    continue
  fi

  if ! zcat "$copia" | docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG" \
       psql -U "$POSTGRES_USER" -d "$tmpdb" -q >/dev/null 2>&1; then
    FALLOS+=("$db: la restauracion dio errores")
    psql_ -d postgres -q -c "DROP DATABASE IF EXISTS \"$tmpdb\";" >/dev/null 2>&1
    continue
  fi

  for par in $(comprobar "$db"); do
    tabla="${par%%:*}"; minimo="${par##*:}"
    filas=$(psql_ -d "$tmpdb" -t -A -c "SELECT count(*) FROM \"$tabla\";" 2>/dev/null | tr -d '[:space:]')
    if ! [ "${filas:-0}" -ge "$minimo" ] 2>/dev/null; then
      FALLOS+=("$db.$tabla: ${filas:-sin leer} filas, se esperaban $minimo o mas")
      echo "  MAL   $tabla: ${filas:-sin leer} filas (minimo $minimo)"
    else
      echo "  ok    $tabla: $filas filas"
    fi
  done

  # Lo que de verdad duele: las credenciales de sesion de WhatsApp.
  if [ "$db" != "chatwoot" ]; then
    creds=$(psql_ -d "$tmpdb" -t -A -c "SELECT coalesce(length(creds),0) FROM \"Session\" LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
    if [ "${creds:-0}" -gt 100 ] 2>/dev/null; then
      echo "  ok    sesion de WhatsApp presente ($creds bytes) — restaurar NO obligaria a reescanear el QR"
    else
      FALLOS+=("$db: la copia NO lleva credenciales de sesion; restaurar obligaria a reescanear el QR")
      echo "  MAL   sin credenciales de sesion"
    fi
  fi

  psql_ -d postgres -q -c "DROP DATABASE IF EXISTS \"$tmpdb\";" >/dev/null 2>&1
  echo "  (base temporal borrada)"
done

echo
if [ ${#FALLOS[@]} -gt 0 ]; then
  avisar_fallo "URGENTE: la prueba de restauracion del CRM ha fallado. Problemas: ${FALLOS[*]}. Las copias podrian no servir."
  exit 1
fi
echo "RESULTADO: las copias se restauran correctamente y llevan las sesiones de WhatsApp."
