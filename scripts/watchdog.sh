#!/bin/sh
# =============================================================================
#  Vigilante de sesiones. Corre dentro de un contenedor con el socket de Docker.
#
#  Cada WATCH_INTERVAL segundos pregunta a CADA numero por su estado.
#  Escalada, por numero y sin tocar al otro:
#     fallo 1-2 -> POST /instance/restart   (reconexion suave, no pide QR)
#     fallo 3   -> docker restart wacrm-evolution-nX
#     fallo 5   -> avisa al webhook: hace falta reescanear el QR
#  Cuando vuelve a "open" avisa de la recuperacion y resetea el contador.
#
#  ⚠️ "connecting" NO ES UNA CAIDA. Es el estado normal mientras el motor
#  esta negociando con WhatsApp, y esa negociacion tarda. Si se reinicia la
#  instancia en mitad del saludo, el socket se aborta a medias y el motor abre
#  otro; el anterior no siempre muere, y entonces WhatsApp ve DOS sockets con
#  la misma sesion y echa a uno con "conflict: replaced". El que se queda
#  vuelve a intentarlo, y se entra en una tormenta que se retroalimenta:
#  ~70 desconexiones por minuto, el numero inservible, y el vigilante
#  reiniciando cada 60s creyendo que ayuda.
#  Paso el 24-Ago-2026 con el numero 2 y estuvo una hora sin servicio.
#
#  De ahi las tres reglas nuevas:
#    1. "connecting" solo cuenta como problema si NO SE MUEVE de ahi durante
#       GRACIA_CONNECTING comprobaciones seguidas.
#    2. A una instancia en "connecting" NUNCA se le manda restart suave: es
#       justo lo que crea el socket duplicado. Si se atasca, se reinicia el
#       contenedor entero, que es lo unico que se lleva por delante los
#       sockets huerfanos.
#    3. Entre dos reinicios del mismo numero tienen que pasar al menos
#       ENFRIAMIENTO segundos. Sin esto, un fallo persistente convierte al
#       vigilante en un bucle de reinicios.
#
#  CASO APARTE: la sesion cerrada A PROPOSITO (logout).
#  Si desde el movil se quita el dispositivo vinculado, WhatsApp cierra la
#  sesion con un stream:error 401 / conflict device_removed. Eso NO se arregla
#  reconectando ni reiniciando: hace falta un QR nuevo, por definicion del
#  protocolo. Ahi la escalada de arriba solo gasta minutos, asi que la saltamos
#  y avisamos de inmediato.
# =============================================================================
INTERVAL="${WATCH_INTERVAL:-60}"
# Cuantas comprobaciones seguidas se le permite a un numero estar "connecting"
# antes de considerarlo atascado. Con el intervalo por defecto son 5 minutos:
# de sobra para un saludo normal, que tarda segundos.
GRACIA_CONNECTING="${WATCH_GRACIA_CONNECTING:-5}"
# Minimo entre dos reinicios del MISMO numero.
ENFRIAMIENTO="${WATCH_ENFRIAMIENTO:-600}"
# En el contenedor es /state (un volumen). Se puede cambiar para poder probar
# la logica fuera del contenedor sin escribir en la raiz del sistema.
STATE_DIR="${WATCH_STATE_DIR:-/state}"
mkdir -p "$STATE_DIR"

ahora() { date +%s; }

# ¿Puedo reiniciar este numero, o acabo de hacerlo?
# Devuelve 0 (si) o 1 (no). Registra la marca cuando concede el permiso.
puedo_reiniciar() {
  fr="$STATE_DIR/$1.ultimo_reinicio"
  ultimo=$(cat "$fr" 2>/dev/null || echo 0)
  t=$(ahora)
  if [ $((t - ultimo)) -lt "$ENFRIAMIENTO" ]; then
    echo "[watchdog] $1: hace $((t - ultimo))s del ultimo reinicio, espero (enfriamiento ${ENFRIAMIENTO}s). Reiniciar en bucle empeora las cosas."
    return 1
  fi
  echo "$t" > "$fr"
  return 0
}

notify() {
  echo "[watchdog] $1"
  # Escapamos para JSON: primero las barras, luego las comillas, y las
  # nuevas lineas fuera (el aviso va en una sola linea).
  esc=$(printf '%s' "$1" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')

  # Telegram no es un webhook generico: ademas del texto hay que decirle a QUE
  # chat va. Sin chat_id la API responde 400 y el aviso se pierde en silencio.
  if [ -n "$ALERT_TELEGRAM_TOKEN" ] && [ -n "$ALERT_TELEGRAM_CHAT_ID" ]; then
    wget -qO- --header='Content-Type: application/json' \
         --post-data="{\"chat_id\":\"$ALERT_TELEGRAM_CHAT_ID\",\"text\":\"$esc\",\"disable_web_page_preview\":true}" \
         "https://api.telegram.org/bot$ALERT_TELEGRAM_TOKEN/sendMessage" >/dev/null 2>&1 || true
  fi

  # Webhook generico (Slack, Discord, n8n...). Se pueden usar los dos a la vez.
  [ -z "$ALERT_WEBHOOK_URL" ] && return 0
  wget -qO- --header='Content-Type: application/json' \
       --post-data="{\"text\":\"$esc\",\"content\":\"$esc\",\"message\":\"$esc\"}" \
       "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# Devuelve la marca de tiempo del ultimo cierre de sesion DELIBERADO, o vacio.
#
# Evolution guarda el motivo de la ultima desconexion en la ficha de la
# instancia. Ojo: esos campos son historicos, siguen ahi despues de reconectar,
# asi que NO basta con encontrarlos. Lo que identifica un logout nuevo es su
# fecha (disconnectionAt), que por eso devolvemos para poder compararla.
logout_de() {
  ficha=$(wget -qO- --header="apikey: $2" --timeout=15 \
          "http://$1:8080/instance/fetchInstances?instanceName=$3" 2>/dev/null)
  case "$ficha" in
    *device_removed*|*'"disconnectionReasonCode":401'*|*loggedOut*) ;;
    *) return 0 ;;
  esac
  # "disconnectionAt":"2026-08-24T13:21:55.677Z"  ->  2026-08-24T13:21:55.677Z
  echo "$ficha" | sed -n 's/.*"disconnectionAt":"\([^"]*\)".*/\1/p'
}

check() {
  n="$1"; container="$2"; instance="$3"; key="$4"
  f="$STATE_DIR/$n.fails"
  fl="$STATE_DIR/$n.logout"
  fc="$STATE_DIR/$n.connecting"
  fails=$(cat "$f" 2>/dev/null || echo 0)

  state=$(wget -qO- --header="apikey: $key" --timeout=15 \
          "http://$container:8080/instance/connectionState/$instance" 2>/dev/null)

  case "$state" in
    *'"state":"open"'*)
      [ "$fails" -gt 0 ] && notify "OK: el numero $n ($instance) volvio a estar conectado"
      echo 0 > "$f"
      # Se borran TODOS los rastros, incluido el contador de pasos. Si no, la
      # proxima caida empezaria con los intentos de arreglo ya gastados y se
      # saltaria directa al aviso de "reescanea el QR".
      rm -f "$fl" "$fc" "$STATE_DIR/$n.pasos"
      return 0 ;;
  esac

  # --- "connecting": esta negociando, no esta caido ---------------------------
  # Le damos margen. Solo si NO SALE de "connecting" en varias comprobaciones
  # seguidas lo damos por atascado, y entonces se reinicia el CONTENEDOR, nunca
  # la instancia: el restart suave sobre un socket a medias es lo que duplica
  # sockets y desata la tormenta de "conflict: replaced".
  case "$state" in
    *'"state":"connecting"'*)
      seguidas=$(( $(cat "$fc" 2>/dev/null || echo 0) + 1 ))
      echo "$seguidas" > "$fc"
      if [ "$seguidas" -lt "$GRACIA_CONNECTING" ]; then
        echo "[watchdog] $n: conectando ($seguidas/$GRACIA_CONNECTING). Es normal, no toco nada."
        return 0
      fi
      echo "[watchdog] $n: lleva $seguidas comprobaciones atascado en 'connecting'."
      # 🚨 UN NUMERO QUE ESPERA UN ESCANEO TAMBIEN VIVE EN "connecting".
      # Reiniciarle el motor le invalida el codigo justo mientras una persona
      # lo esta enfocando con la camara. Hay DOS formas de estar esperando:
      #
      #   a) nunca se ha vinculado          -> no tiene ownerJid
      #   b) se cerro la sesion desde el     -> SI tiene ownerJid, asi que la
      #      movil y aun no se ha               comprobacion de (a) NO lo pilla
      #      reescaneado
      #
      # El caso (b) es el que fallaba: el 31-Ago-2026 el vigilante reinicio el
      # motor del numero 1 mientras el cliente intentaba reescanear, y el codigo
      # dejaba de valer en sus manos sin explicacion. Se reconoce por el fichero
      # de logout, que se escribe al detectar el cierre y SOLO se borra cuando
      # el numero vuelve a estar "open". Si sigue puesto, seguimos esperando.
      if [ -f "$fl" ]; then
        echo "[watchdog] $n: esperando a que alguien reescanee el QR (sesion cerrada el $(cat "$fl")). Reiniciar le tumbaria el codigo. No lo toco."
        return 0
      fi
      # Caso (a): se distingue por el ownerJid, que solo tiene un numero ya
      # vinculado alguna vez.
      if ! wget -qO- --header="apikey: $key" --timeout=15 \
             "http://$container:8080/instance/fetchInstances?instanceName=$instance" 2>/dev/null \
           | grep -q '"ownerJid":"[^"]'; then
        echo "[watchdog] $n: nunca se ha vinculado, esta esperando a que alguien escanee el QR. No lo toco."
        return 0
      fi
      if puedo_reiniciar "$n"; then
        docker restart "$container" >/dev/null 2>&1 || true
        echo 0 > "$fc"
        notify "AVISO: el numero $n ($instance) se ha quedado atascado conectando. Reinicio el motor de ESE numero. El otro sigue operativo."
      fi
      return 0 ;;
  esac
  rm -f "$fc"

  # La instancia todavia NO existe (aun no se ha escaneado el QR de ese numero).
  # Si el motor responde en la raiz pero no conoce la instancia, no hay nada
  # roto que reparar: reiniciar el contenedor no la crearia. Sin esta
  # comprobacion el vigilante reinicia los motores en bucle para siempre.
  if ! echo "$state" | grep -q '"state"'; then
    if wget -qO- --timeout=10 "http://$container:8080/" 2>/dev/null | grep -q '"status":200'; then
      echo "[watchdog] $n: el motor esta sano pero la instancia '$instance' aun no existe (falta escanear el QR). No hago nada."
      echo 0 > "$f"
      return 0
    fi
  fi

  # Sesion cerrada a proposito desde el movil: reiniciar no puede arreglarlo.
  # Avisamos una sola vez por cada logout (los distinguimos por su fecha) y
  # dejamos de tocar el motor hasta que alguien reescanee.
  cerrada=$(logout_de "$container" "$key" "$instance")
  if [ -n "$cerrada" ]; then
    if [ "$cerrada" != "$(cat "$fl" 2>/dev/null)" ]; then
      echo "$cerrada" > "$fl"
      echo 0 > "$f"
      rm -f "$STATE_DIR/$n.pasos"
      notify "URGENTE: se ha cerrado la sesion del numero $n ($instance) desde el movil (dispositivo vinculado eliminado, $cerrada). Reiniciar NO lo arregla: hay que volver a escanear el QR en la pagina de vinculacion. El otro numero sigue operativo."
    else
      echo "[watchdog] $n: sesion cerrada desde el movil ($cerrada), esperando a que se reescanee el QR. No reinicio nada."
    fi
    return 0
  fi

  fails=$((fails + 1)); echo "$fails" > "$f"
  echo "[watchdog] $n caido (intento $fails) estado=$state"

  # OJO: hay DOS contadores y no son lo mismo.
  #   fails -> comprobaciones seguidas caido. Mide cuanto lleva sin servicio.
  #   pasos -> intentos de arreglo que de VERDAD se han hecho.
  # Se separan por el enfriamiento: si un reinicio se pospone, ese ciclo suma
  # a "fails" pero no a "pasos". Con un solo contador el aviso de "hace falta
  # reescanear el QR" saltaria a los 5 minutos sin haber probado siquiera a
  # reiniciar el contenedor, o sea acusando al movil de un fallo que aun no se
  # ha intentado reparar.
  fp="$STATE_DIR/$n.pasos"
  pasos=$(cat "$fp" 2>/dev/null || echo 0)

  if [ "$pasos" -le 1 ]; then
    # Aqui el estado es "close": el socket ya esta cerrado, no hay ninguno a
    # medias que duplicar, asi que la reconexion suave es segura.
    if puedo_reiniciar "$n"; then
      wget -qO- --header="apikey: $key" --post-data='' \
           "http://$container:8080/instance/restart/$instance" >/dev/null 2>&1 || true
      echo $((pasos + 1)) > "$fp"
      notify "AVISO: $n ($instance) desconectado. Reconexion suave lanzada. El otro numero sigue operativo."
    fi
  elif [ "$pasos" -le 3 ]; then
    if puedo_reiniciar "$n"; then
      docker restart "$container" >/dev/null 2>&1 || true
      echo $((pasos + 1)) > "$fp"
      notify "AVISO: reiniciando el contenedor de $n ($container). El resto de numeros NO se ve afectado."
    fi
  elif [ "$pasos" -eq 4 ]; then
    echo $((pasos + 1)) > "$fp"
    notify "URGENTE: $n ($instance) sigue caido despues de $fails comprobaciones y de haber probado a reconectarlo y a reiniciar su motor. Probablemente hay que reescanear el QR: ejecutar ./scripts/provision.sh $n"
  fi
}

notify "watchdog arrancado (cada ${INTERVAL}s)"
while true; do
  check n1 wacrm-evolution-n1 "$N1_INSTANCE" "$N1_API_KEY"
  check n2 wacrm-evolution-n2 "$N2_INSTANCE" "$N2_API_KEY"
  sleep "$INTERVAL"
done
