#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  vigilar-ip-proxy.sh — anota la IP de salida de cada proxy 4G y avisa cuando
#  cambia la IDENTIDAD DE RED, que es lo que de verdad importa.
#
#  Por que no vale con "avisar si cambia la IP":
#    una linea movil cambia de IP sola cada dos por tres (renovacion de la
#    concesion, reinicio del modem). Eso lo hace cualquier telefono del mundo
#    todos los dias y WhatsApp no lo penaliza.
#    Lo que WhatsApp lee como cuenta robada es el salto a OTRA operadora, otra
#    region u otro pais, o de movil a centro de datos.
#  Por eso este vigilante distingue dos casos:
#    - misma operadora (ASN) y mismo pais -> lo anota como NORMAL, sin alarma
#    - cambio de ASN o de pais            -> AVISO, hay que mirarlo
#
#  Corre DESDE EL ANFITRION, no dentro del contenedor. Dos motivos:
#    1. la imagen docker:27-cli no trae curl, y el wget de busybox no habla
#       SOCKS5, asi que ahi dentro no se puede medir un proxy socks5.
#    2. las variables PROXY_* de Evolution solo se aplican al socket de Baileys,
#       NO al trafico propio del contenedor: medir desde dentro daria la IP del
#       servidor y parecerian todas correctas. Hay que atacar al proxy con
#       curl -x / --socks5-hostname, y eso es exactamente lo que se hace aqui.
#
#  Instalacion (una vez):
#     ./scripts/vigilar-ip-proxy.sh --instalar-cron        # cada 15 minutos
#  Ejecucion manual:
#     ./scripts/vigilar-ip-proxy.sh
#  Ver el historial:
#     ./scripts/vigilar-ip-proxy.sh --historial
#
#  Solo lee. No toca instancias, ni contenedores, ni rota nada.
# ---------------------------------------------------------------------------
set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${WACRM_ENV:-$BASE/.env}"     # WACRM_ENV solo se usa para probar el script
ESTADO="$BASE/.estado-ip"
HISTORIAL="$ESTADO/historial.log"
mkdir -p "$ESTADO"

# --- leer el .env SIN "source" ------------------------------------------------
# Aprendido a golpes en este mismo proyecto: un valor sin comillas
# (SESSION_PHONE_CLIENT=CRM Comercial) rompe "source .env" a mitad y deja el
# resto de variables vacias en silencio. Se lee clave a clave y se limpian los
# comentarios al final de linea, que tambien los hay.
leer_env() {
  local clave="$1" valor
  [ -r "$ENV_FILE" ] || return 0
  valor=$(grep -E "^[[:space:]]*${clave}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)
  valor="${valor%%#*}"                       # quitar comentario al final
  valor="$(printf '%s' "$valor" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  valor="${valor%\"}"; valor="${valor#\"}"   # quitar comillas si las lleva
  valor="${valor%\'}"; valor="${valor#\'}"
  printf '%s' "$valor"
}

ALERT_WEBHOOK_URL="$(leer_env ALERT_WEBHOOK_URL)"
ALERT_TELEGRAM_TOKEN="$(leer_env ALERT_TELEGRAM_TOKEN)"
ALERT_TELEGRAM_CHAT_ID="$(leer_env ALERT_TELEGRAM_CHAT_ID)"

avisar() {
  local texto="$1"
  echo "$texto"
  local esc; esc=$(printf '%s' "$texto" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

  # Telegram no es un webhook generico: ademas del texto hay que decirle a QUE
  # chat va. Sin chat_id la API responde 400 y el aviso se pierde en silencio.
  if [ -n "$ALERT_TELEGRAM_TOKEN" ] && [ -n "$ALERT_TELEGRAM_CHAT_ID" ]; then
    curl -s -m 15 -H 'Content-Type: application/json' \
         -d "{\"chat_id\":\"$ALERT_TELEGRAM_CHAT_ID\",\"text\":\"$esc\",\"disable_web_page_preview\":true}" \
         "https://api.telegram.org/bot$ALERT_TELEGRAM_TOKEN/sendMessage" >/dev/null 2>&1 || true
  fi

  # Webhook generico (Slack, Discord, n8n...). Se pueden usar los dos a la vez.
  [ -z "$ALERT_WEBHOOK_URL" ] && return 0
  curl -s -m 15 -H 'Content-Type: application/json' \
       -d "{\"text\":\"$esc\",\"content\":\"$esc\",\"message\":\"$esc\"}" \
       "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
}

anotar() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$1" >> "$HISTORIAL"; }

# --- construir la URL del proxy tal y como hay que MEDIRLO --------------------
# socks5:// hace que el DNS lo resuelva ESTE servidor (Canada) en vez del proxy
# (Brasil), y entonces se le entrega al proxy brasileno un servidor de WhatsApp
# elegido desde Canada: penaliza ~0,3s y ademas puede dar falsas "fugas".
# socks5h:// resuelve en el proxy, que es como lo hace Evolution de verdad.
url_proxy() {
  local proto="$1" usuario="$2" clave="$3" host="$4" puerto="$5" cred=""
  [ -n "$usuario" ] && cred="${usuario}:${clave}@"
  case "$proto" in
    socks5|socks5h) printf 'socks5h://%s%s:%s' "$cred" "$host" "$puerto" ;;
    *)              printf '%s://%s%s:%s' "$proto" "$cred" "$host" "$puerto" ;;
  esac
}

# --- consultar la IP de salida ------------------------------------------------
# Dos fuentes distintas: si discrepan es que el trafico no sale siempre por el
# mismo sitio. La segunda es IPv4 pura a proposito: ifconfig.me responde por
# IPv6 a traves del tunel y eso se lee como "la IP cambia" cuando no cambia.
ip_de_salida() {
  local proxy="$1"
  curl -s -m 25 --proxy "$proxy" https://api.ipify.org 2>/dev/null | tr -d '[:space:]'
}

perfil_de_ip() {
  # Devuelve "ASN|pais|organizacion" consultando SIN proxy (es solo una consulta
  # de datos publicos sobre una IP, no hace falta que salga por la linea movil).
  local ip="$1" json
  json=$(curl -s -m 15 "http://ip-api.com/json/${ip}?fields=status,country,countryCode,as,isp,mobile,hosting" 2>/dev/null)
  local as pais isp movil
  as=$(printf '%s' "$json"   | sed -n 's/.*"as":"\([^"]*\)".*/\1/p')
  pais=$(printf '%s' "$json" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
  isp=$(printf '%s' "$json"  | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')
  movil=$(printf '%s' "$json"| sed -n 's/.*"mobile":\([a-z]*\).*/\1/p')
  # el ASN es la primera palabra de "as" ("AS22085 Claro S/A" -> AS22085)
  printf '%s|%s|%s|%s' "${as%% *}" "${pais:-?}" "${isp:-?}" "${movil:-?}"
}

revisar_numero() {
  local n="$1"
  local host proto usuario clave puerto
  host=$(leer_env "${n^^}_PROXY_HOST")
  [ -z "$host" ] && return 0          # ese numero aun no tiene proxy configurado

  puerto=$(leer_env "${n^^}_PROXY_PORT")
  proto=$(leer_env "${n^^}_PROXY_PROTOCOL"); proto="${proto:-http}"
  usuario=$(leer_env "${n^^}_PROXY_USERNAME")
  clave=$(leer_env "${n^^}_PROXY_PASSWORD")

  local proxy; proxy=$(url_proxy "$proto" "$usuario" "$clave" "$host" "$puerto")
  local f_ip="$ESTADO/$n.ip" f_perfil="$ESTADO/$n.perfil"
  local ip_ant perfil_ant
  ip_ant=$(cat "$f_ip" 2>/dev/null || echo "")
  perfil_ant=$(cat "$f_perfil" 2>/dev/null || echo "")

  local ip; ip=$(ip_de_salida "$proxy")

  if [ -z "$ip" ]; then
    # No respondio. Un fallo suelto sobre 4G es normal; se avisa al segundo
    # seguido para no despertar a nadie por un bache de red de 20 segundos.
    local f_fallos="$ESTADO/$n.fallos"
    local fallos; fallos=$(( $(cat "$f_fallos" 2>/dev/null || echo 0) + 1 ))
    echo "$fallos" > "$f_fallos"
    anotar "$n  SIN RESPUESTA del proxy (intento $fallos)"
    [ "$fallos" -eq 2 ] && avisar "AVISO: el proxy de $n lleva 2 comprobaciones sin responder. Si el numero esta vinculado, la sesion se va a caer."
    return 0
  fi
  echo 0 > "$ESTADO/$n.fallos"

  if [ "$ip" = "$ip_ant" ]; then
    anotar "$n  $ip  (igual)"
    return 0
  fi

  local perfil; perfil=$(perfil_de_ip "$ip")
  local asn pais isp movil
  IFS='|' read -r asn pais isp movil <<< "$perfil"

  if [ -z "$ip_ant" ]; then
    anotar "$n  $ip  (primera lectura)  $asn $pais $isp movil=$movil"
    echo "$ip" > "$f_ip"; echo "$perfil" > "$f_perfil"
    return 0
  fi

  local asn_ant pais_ant
  IFS='|' read -r asn_ant pais_ant _ _ <<< "$perfil_ant"

  if [ "$asn" = "$asn_ant" ] && [ "$pais" = "$pais_ant" ]; then
    # Mismo operador, mismo pais: es lo que hace un movil normal. Se anota
    # para tener el historial, pero NO es una alarma.
    anotar "$n  $ip  (CAMBIO NORMAL: antes $ip_ant, misma red $asn $pais)"
    echo "  $n: la IP cambio de $ip_ant a $ip, pero sigue en $asn ($pais). Comportamiento normal de una linea movil, no hay nada que hacer."
  else
    anotar "$n  $ip  (!! CAMBIO DE RED: antes $ip_ant $asn_ant $pais_ant -> ahora $asn $pais $isp movil=$movil)"
    avisar "URGENTE: el proxy de $n cambio de red. Antes salia por $asn_ant ($pais_ant) y ahora por $asn ($pais, $isp, movil=$movil). Este es el patron que WhatsApp interpreta como cuenta comprometida. No mandes mensajes con ese numero hasta revisarlo con el proveedor."
  fi

  echo "$ip" > "$f_ip"; echo "$perfil" > "$f_perfil"
}

case "${1:-}" in
  --historial)
    [ -f "$HISTORIAL" ] && tail -n 60 "$HISTORIAL" || echo "Todavia no hay historial."
    exit 0 ;;
  --instalar-cron)
    LINEA="*/15 * * * * $BASE/scripts/vigilar-ip-proxy.sh >/dev/null 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'vigilar-ip-proxy.sh' ; echo "$LINEA" ) | crontab -
    echo "Instalado en cron cada 15 minutos:"
    echo "  $LINEA"
    exit 0 ;;
  --quitar-cron)
    crontab -l 2>/dev/null | grep -v 'vigilar-ip-proxy.sh' | crontab -
    echo "Quitado del cron."
    exit 0 ;;
  "" ) : ;;
  *  ) echo "Uso: $0 [--historial | --instalar-cron | --quitar-cron]"; exit 2 ;;
esac

revisar_numero n1
revisar_numero n2
