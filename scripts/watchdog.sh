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
# =============================================================================
INTERVAL="${WATCH_INTERVAL:-60}"
STATE_DIR=/state
mkdir -p "$STATE_DIR"

notify() {
  echo "[watchdog] $1"
  [ -z "$ALERT_WEBHOOK_URL" ] && return 0
  esc=$(printf '%s' "$1" | sed 's/"/\\"/g')
  wget -qO- --header='Content-Type: application/json' \
       --post-data="{\"text\":\"$esc\",\"content\":\"$esc\",\"message\":\"$esc\"}" \
       "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
}

check() {
  n="$1"; container="$2"; instance="$3"; key="$4"
  f="$STATE_DIR/$n.fails"
  fails=$(cat "$f" 2>/dev/null || echo 0)

  state=$(wget -qO- --header="apikey: $key" --timeout=15 \
          "http://$container:8080/instance/connectionState/$instance" 2>/dev/null)

  case "$state" in
    *'"state":"open"'*)
      [ "$fails" -gt 0 ] && notify "OK: el numero $n ($instance) volvio a estar conectado"
      echo 0 > "$f"
      return 0 ;;
  esac

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

  fails=$((fails + 1)); echo "$fails" > "$f"
  echo "[watchdog] $n caido (intento $fails) estado=$state"

  if [ "$fails" -le 2 ]; then
    wget -qO- --header="apikey: $key" --post-data='' \
         "http://$container:8080/instance/restart/$instance" >/dev/null 2>&1 || true
    notify "AVISO: $n ($instance) desconectado. Reconexion suave lanzada. El otro numero sigue operativo."
  elif [ "$fails" -le 4 ]; then
    docker restart "$container" >/dev/null 2>&1 || true
    notify "AVISO: reiniciando el contenedor de $n ($container). El resto de numeros NO se ve afectado."
  elif [ "$fails" -eq 5 ]; then
    notify "URGENTE: $n ($instance) lleva 5 comprobaciones caido. Probablemente hay que reescanear el QR: ejecutar ./scripts/provision.sh $n"
  fi
}

notify "watchdog arrancado (cada ${INTERVAL}s)"
while true; do
  check n1 wacrm-evolution-n1 "$N1_INSTANCE" "$N1_API_KEY"
  check n2 wacrm-evolution-n2 "$N2_INSTANCE" "$N2_API_KEY"
  sleep "$INTERVAL"
done
