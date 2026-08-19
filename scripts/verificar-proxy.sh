#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  verificar-proxy.sh — las 5 comprobaciones de docs/PROXIES-Y-CALENTAMIENTO.md
#  automatizadas, con veredicto APTO / NO APTO.
#
#  Uso:
#     ./scripts/verificar-proxy.sh "http://usuario:clave@host:puerto"
#     ./scripts/verificar-proxy.sh "socks5://usuario:clave@host:puerto" --pais BR
#     ./scripts/verificar-proxy.sh "$PROXY" --horas 2      # vigilancia de IP
#     ./scripts/verificar-proxy.sh "$PROXY" --horas 0      # saltar la vigilancia
#
#  INTERVALO=<segundos> acorta la espera entre lecturas (por defecto 600).
#  Solo para probar el propio script: para juzgar un proxy hay que dejar 600.
#
#  Salida: informe en pantalla + informe-proxy-<fecha>.txt junto al script.
#  NO toca el servidor ni ninguna instancia. Solo lee. Es seguro correrlo
#  las veces que haga falta.
# ---------------------------------------------------------------------------
set -uo pipefail

PROXY="${1:-}"
PAIS_ESPERADO="BR"
HORAS=2

shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --pais)  PAIS_ESPERADO="${2:-BR}"; shift 2 ;;
    --horas) HORAS="${2:-2}";          shift 2 ;;
    *) echo "Opcion desconocida: $1"; exit 2 ;;
  esac
done

if [ -z "$PROXY" ]; then
  echo "Uso: $0 \"http://usuario:clave@host:puerto\" [--pais BR] [--horas 2]"
  exit 2
fi

C_OK=$'\033[32m'; C_MAL=$'\033[31m'; C_AVISO=$'\033[33m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_OK=""; C_MAL=""; C_AVISO=""; C_OFF=""; }

FALLOS=0
AVISOS=0
INFORME="$(dirname "$0")/informe-proxy-$(date +%Y%m%d-%H%M).txt"

log()   { echo "$*" | tee -a "$INFORME" ; }
ok()    { log "  ${C_OK}[OK]${C_OFF}    $*" ; }
mal()   { log "  ${C_MAL}[FALLO]${C_OFF} $*" ; FALLOS=$((FALLOS+1)) ; }
aviso() { log "  ${C_AVISO}[AVISO]${C_OFF} $*" ; AVISOS=$((AVISOS+1)) ; }

# el proxy con la contrasena tapada, para poder pegar el informe sin regalarla
PROXY_SEGURO=$(echo "$PROXY" | sed -E 's#(//[^:]+:)[^@]+@#\1********@#')

log "==========================================================="
log " Verificacion de proxy 4G — $(date '+%Y-%m-%d %H:%M:%S %Z')"
log " Proxy: $PROXY_SEGURO"
log " Pais esperado: $PAIS_ESPERADO"
log "==========================================================="

# --------------------------------------------------------------- 0) referencia
log ""
log "0) IP del servidor SIN proxy (referencia)"
IP_DIRECTA=$(curl -4 -s --max-time 20 https://api.ipify.org)
if [ -z "$IP_DIRECTA" ]; then
  aviso "no pude averiguar la IP directa del servidor (no es grave)"
  IP_DIRECTA="desconocida"
else
  log "  El servidor sale normalmente por: $IP_DIRECTA"
fi

# --------------------------------------------------- 1) responde y que IP da
log ""
log "1) El proxy responde y da una IP de salida"
IP_PROXY=$(curl -4 -s --max-time 30 -x "$PROXY" https://api.ipify.org)
if [ -z "$IP_PROXY" ]; then
  mal "el proxy NO responde. Revisa host, puerto, protocolo y credenciales."
  log ""
  log "VEREDICTO: NO APTO (ni siquiera conecta)"
  exit 1
fi
if ! echo "$IP_PROXY" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  mal "el proxy respondio algo que no es una IP: $(echo "$IP_PROXY" | head -c 120)"
  log ""
  log "VEREDICTO: NO APTO"
  exit 1
fi
ok "responde. IP de salida: $IP_PROXY"

if [ "$IP_PROXY" = "$IP_DIRECTA" ]; then
  mal "la IP del proxy es LA MISMA que la del servidor: el trafico NO esta pasando por el proxy."
else
  ok "la IP es distinta a la del servidor: el trafico si sale por el proxy"
fi

# ------------------------------------------- 2) es movil de verdad? pais? ASN?
log ""
log "2) Es 4G de una operadora real, y del pais correcto"
INFO=$(curl -s --max-time 25 "https://ipinfo.io/${IP_PROXY}/json")
ORG=$(echo "$INFO"  | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
PAIS=$(echo "$INFO" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
CIUDAD=$(echo "$INFO" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

# segunda fuente, porque ipinfo a veces se queda corto en el campo org
INFO2=$(curl -s --max-time 25 "http://ip-api.com/json/${IP_PROXY}?fields=status,country,countryCode,isp,org,as,mobile,proxy,hosting")
ISP=$(echo "$INFO2"    | sed -n 's/.*"isp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
AS=$(echo "$INFO2"     | sed -n 's/.*"as"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
PAIS2=$(echo "$INFO2"  | sed -n 's/.*"countryCode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
ES_MOVIL=$(echo "$INFO2"   | sed -n 's/.*"mobile"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
ES_HOSTING=$(echo "$INFO2" | sed -n 's/.*"hosting"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
ES_PROXY=$(echo "$INFO2"   | sed -n 's/.*"proxy"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')

log "  Organizacion (ipinfo): ${ORG:-desconocida}"
log "  Operadora   (ip-api):  ${ISP:-desconocida}"
log "  ASN:                   ${AS:-desconocido}"
log "  Ubicacion:             ${CIUDAD:-?}, ${PAIS:-?}"

PAIS_REAL="${PAIS:-$PAIS2}"
if [ -n "$PAIS_REAL" ] && [ "$PAIS_REAL" = "$PAIS_ESPERADO" ]; then
  ok "la IP sale de $PAIS_ESPERADO, igual que la linea de WhatsApp"
elif [ -z "$PAIS_REAL" ]; then
  aviso "no pude determinar el pais"
else
  mal "la IP sale de '$PAIS_REAL' y la linea es de '$PAIS_ESPERADO'. Incoherencia visible desde fuera."
fi

# centro de datos disfrazado de movil
HOSTING_PAT='amazon|aws|google|microsoft|azure|ovh|hetzner|digitalocean|linode|vultr|contabo|leaseweb|scaleway|oracle|choopa|m247|datacamp|hosting|data ?cent|cloud|colo|server|vps'
CAMPOS="${ORG} ${ISP} ${AS}"
if echo "$CAMPOS" | grep -qiE "$HOSTING_PAT"; then
  mal "huele a CENTRO DE DATOS, no a operadora movil: '${ORG:-}${ISP:+ / $ISP}'. Esto es peor que no poner proxy."
elif [ "$ES_HOSTING" = "true" ]; then
  mal "ip-api lo marca como hosting (centro de datos). DESCARTAR."
else
  ok "no aparece como centro de datos"
fi

if [ "$ES_MOVIL" = "true" ]; then
  ok "ip-api lo clasifica como red MOVIL"
elif [ "$ES_MOVIL" = "false" ]; then
  aviso "ip-api NO lo clasifica como movil. Puede ser un fallo de su base de datos, pero hay que preguntarle al proveedor por la operadora exacta."
else
  aviso "ip-api no devolvio la clasificacion movil/fija"
fi

if [ "$ES_PROXY" = "true" ]; then
  aviso "la IP ya esta catalogada publicamente como proxy/VPN. No es descarte automatico en 4G, pero suma riesgo."
fi

# ------------------------------------------------ 3) latencia y acceso WhatsApp
log ""
log "3) Latencia y acceso a WhatsApp a traves del proxy"
for DESTINO in https://web.whatsapp.com https://mmg.whatsapp.net; do
  MED=$(curl -4 -x "$PROXY" -o /dev/null -s --max-time 40 \
        -w '%{http_code} %{time_appconnect} %{time_total}' "$DESTINO")
  CODIGO=$(echo "$MED" | awk '{print $1}')
  # time_appconnect = TLS completado CONTRA EL DESTINO a traves del tunel,
  # o sea el camino entero. time_connect solo llegaria hasta el proxy.
  T_CON=$(echo "$MED"  | awk '{print $2}')
  T_TOT=$(echo "$MED"  | awk '{print $3}')
  log "  $DESTINO -> HTTP $CODIGO | handshake extremo a extremo ${T_CON}s | total ${T_TOT}s"

  case "$CODIGO" in
    # 404 en mmg.whatsapp.net es lo normal: es el CDN de multimedia y no sirve
    # una pagina en la raiz. Lo que importa es que la conexion se establezca.
    200|204|301|302|400|403|404|405)
      ok "WhatsApp responde a traves del proxy (HTTP $CODIGO)" ;;
    000)
      mal "no se pudo conectar a $DESTINO por el proxy" ; continue ;;
    *)
      aviso "codigo inesperado $CODIGO en $DESTINO" ;;
  esac

  # umbral de latencia: <0.4 ideal, <0.8 aceptable, >1.5 desconexiones
  VEREDICTO_LAT=$(awk -v t="$T_CON" 'BEGIN{
    if (t=="" || t+0==0)  print "nd";
    else if (t+0 < 0.4)   print "ideal";
    else if (t+0 < 0.8)   print "aceptable";
    else if (t+0 < 1.5)   print "justa";
    else                  print "mala" }')
  case "$VEREDICTO_LAT" in
    ideal|aceptable) ok "latencia $VEREDICTO_LAT (${T_CON}s)" ;;
    justa)  aviso "latencia justa (${T_CON}s). Funcionara, pero con reconexiones ocasionales." ;;
    mala)   mal "latencia mala (${T_CON}s). Va a dar desconexiones constantes." ;;
    nd)     aviso "no pude medir la latencia" ;;
  esac
done

# ---------------------------------------------------- 4) SOCKS5 / HTTP y fugas
log ""
log "4) Coherencia: todo el trafico sale por el mismo sitio"
# OJO: el segundo servicio tiene que ser SOLO IPv4. Con ifconfig.me el proxy
# resolvia por IPv6 y devolvia una direccion v6 legitima que el script leia
# como "la IP esta cambiando" — un falso positivo. curl -4 no sirve aqui:
# controla MI conexion al proxy, no la que el proxy abre hacia el destino.
IP_REPETIDA=$(curl -4 -s --max-time 30 -x "$PROXY" https://ipv4.icanhazip.com)
IP_REPETIDA=$(echo "$IP_REPETIDA" | tr -d '[:space:]')
if [ -z "$IP_REPETIDA" ]; then
  aviso "la segunda fuente (icanhazip) no respondio; no es concluyente"
elif [ "$IP_REPETIDA" = "$IP_PROXY" ]; then
  ok "dos servicios distintos ven la misma IP ($IP_PROXY): no hay fuga"
else
  mal "dos servicios ven IP distintas ($IP_PROXY vs $IP_REPETIDA): la IP ya esta rotando o hay fuga."
fi

# ------------------------------------------------- 5) LA PRUEBA QUE MAS TUMBA
log ""
# comparacion numerica de verdad: con "${HORAS%.*}" un --horas 0.5 se truncaba
# a "0" y la prueba se saltaba sin avisar.
if [ "$(awk -v h="$HORAS" 'BEGIN{print (h+0<=0)?1:0}')" = "1" ]; then
  log "5) Estabilidad de la IP — SALTADA (--horas 0)"
  aviso "sin esta prueba el veredicto NO es definitivo: es la que descarta a mas proveedores"
else
  VUELTAS=$(awk -v h="$HORAS" 'BEGIN{ v=int(h*6); if(v<1)v=1; print v }')
  log "5) Estabilidad de la IP — $VUELTAS lecturas, una cada 10 min (~${HORAS}h)"
  log "   La IP debe ser SIEMPRE la misma. Cualquier cambio = NO APTO."
  CAMBIOS=0
  for i in $(seq 1 "$VUELTAS"); do
    AHORA=$(curl -4 -s --max-time 30 -x "$PROXY" https://api.ipify.org | tr -d '[:space:]')
    MARCA=$(date '+%H:%M:%S')
    if [ -z "$AHORA" ]; then
      log "   $MARCA  lectura $i/$VUELTAS: SIN RESPUESTA"
      aviso "el proxy dejo de responder en la lectura $i (caida momentanea)"
    elif [ "$AHORA" = "$IP_PROXY" ]; then
      log "   $MARCA  lectura $i/$VUELTAS: $AHORA  (igual)"
    else
      log "   $MARCA  lectura $i/$VUELTAS: $AHORA  <-- ¡CAMBIO! (era $IP_PROXY)"
      CAMBIOS=$((CAMBIOS+1))
      IP_PROXY="$AHORA"
    fi
    [ "$i" -lt "$VUELTAS" ] && sleep ${INTERVALO:-600}
  done
  if [ "$CAMBIOS" -eq 0 ]; then
    ok "la IP no se movio en ninguna de las $VUELTAS lecturas"
  else
    mal "la IP cambio $CAMBIOS veces. WhatsApp lee eso como sesion secuestrada. NO APTO."
  fi
fi

# ---------------------------------------------------------------- veredicto
log ""
log "==========================================================="
if [ "$FALLOS" -eq 0 ] && [ "$AVISOS" -eq 0 ]; then
  log " VEREDICTO: ${C_OK}APTO${C_OFF} — se puede vincular el numero por aqui"
elif [ "$FALLOS" -eq 0 ]; then
  log " VEREDICTO: ${C_AVISO}APTO CON RESERVAS${C_OFF} — $AVISOS aviso(s) que revisar con el proveedor"
else
  log " VEREDICTO: ${C_MAL}NO APTO${C_OFF} — $FALLOS fallo(s) y $AVISOS aviso(s)"
  log " No vincules ningun numero por este proxy."
fi
log "==========================================================="
log "Informe guardado en: $INFORME"

[ "$FALLOS" -eq 0 ]
