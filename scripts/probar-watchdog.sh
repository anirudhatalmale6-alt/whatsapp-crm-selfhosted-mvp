#!/bin/sh
# Banco de pruebas del vigilante SIN tocar el servidor.
# Se falsean wget y docker, y se comprueba QUE decide en cada escenario.
set -u
BANCO=$(mktemp -d)
export WATCH_STATE_DIR="$BANCO/state"; mkdir -p "$WATCH_STATE_DIR"; STATE_DIR="$WATCH_STATE_DIR"
ACCIONES="$BANCO/acciones.log"; : > "$ACCIONES"

# --- dobles ---------------------------------------------------------------
cat > "$BANCO/wget" <<'W'
#!/bin/sh
url=""; for a in "$@"; do case "$a" in http*) url="$a";; esac; done
case "$url" in
  *connectionState*) printf '{"instance":{"instanceName":"x","state":"%s"}}' "$(cat "$ESTADO_FALSO")";;
  *fetchInstances*)  cat "$FICHA_FALSA" 2>/dev/null || echo '{}';;
  *instance/restart*) echo "RESTART_SUAVE" >> "$ACCIONES";;
  *api.telegram.org*) echo "TELEGRAM" >> "$ACCIONES";;
  *8080/) echo '{"status":200}';;
esac
W
cat > "$BANCO/docker" <<'D'
#!/bin/sh
[ "$1" = restart ] && echo "RESTART_CONTENEDOR" >> "$ACCIONES"
exit 0
D
chmod +x "$BANCO/wget" "$BANCO/docker"
export PATH="$BANCO:$PATH" ACCIONES
export ALERT_TELEGRAM_TOKEN=t ALERT_TELEGRAM_CHAT_ID=c ALERT_WEBHOOK_URL=""
export ESTADO_FALSO="$BANCO/estado" FICHA_FALSA="$BANCO/ficha"
echo '{}' > "$FICHA_FALSA"

# Cargamos solo las funciones del vigilante (cortando el bucle final).
sed '/^notify "watchdog arrancado/,$d' "$1" > "$BANCO/wd.sh"
. "$BANCO/wd.sh"

correr() { # correr <estado> <veces>
  echo "$1" > "$ESTADO_FALSO"
  i=0; while [ $i -lt $2 ]; do check n1 cont inst clave >/dev/null 2>&1; i=$((i+1)); done
}
cuenta() { c=$(grep -c "^$1$" "$ACCIONES" 2>/dev/null); echo "${c:-0}"; }
resultado() {
  if [ "$2" = "$3" ]; then echo "  ok    $1: $3"
  else echo "  MAL   $1: esperaba $3, salio $2"; FALLOS=$((FALLOS+1)); fi
}
FALLOS=0

echo "=== 1. 'connecting' breve (3 ciclos): NO debe tocar nada ==="
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
correr connecting 3
resultado "restart suave" "$(cuenta RESTART_SUAVE)" 0
resultado "restart contenedor" "$(cuenta RESTART_CONTENEDOR)" 0

echo "=== 2. 'connecting' atascado (8 ciclos): 1 restart de CONTENEDOR, 0 suaves ==="
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
echo '{"ownerJid":"554197552217@s.whatsapp.net"}' > "$FICHA_FALSA"
correr connecting 8
resultado "restart suave (el que rompia)" "$(cuenta RESTART_SUAVE)" 0
resultado "restart contenedor" "$(cuenta RESTART_CONTENEDOR)" 1
echo '{}' > "$FICHA_FALSA"

echo "=== 2b. 'connecting' en un numero SIN vincular: no se toca nunca ==="
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
echo '{"ownerJid":"","name":"x"}' > "$FICHA_FALSA"
correr connecting 12
resultado "restart suave" "$(cuenta RESTART_SUAVE)" 0
resultado "restart contenedor" "$(cuenta RESTART_CONTENEDOR)" 0
echo '{"ownerJid":"554197552217@s.whatsapp.net"}' > "$FICHA_FALSA"

echo "=== 2c. 'connecting' atascado en un numero YA vinculado: si se reinicia ==="
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
correr connecting 8
resultado "restart contenedor" "$(cuenta RESTART_CONTENEDOR)" 1
echo '{}' > "$FICHA_FALSA"

echo "=== 3. 'close' 10 ciclos: el enfriamiento limita a 1 accion ==="
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
correr close 10
total=$(( $(cuenta RESTART_SUAVE) + $(cuenta RESTART_CONTENEDOR) ))
resultado "acciones totales en 10 ciclos" "$total" 1

echo "=== 4. 'close' con enfriamiento a 0: escalada completa y aviso final ==="
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
ENFRIAMIENTO=0 correr close 8
resultado "restart suave" "$(cuenta RESTART_SUAVE)" 2
resultado "restart contenedor" "$(cuenta RESTART_CONTENEDOR)" 2

echo "=== 5. recuperacion: tras volver a 'open' los contadores se limpian ==="
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
ENFRIAMIENTO=0 correr close 8
correr open 1
resultado "ficheros de estado que quedan" "$(ls "$STATE_DIR" | grep -cv '^n1.fails$\|ultimo_reinicio')" 0
: > "$ACCIONES"
ENFRIAMIENTO=0 correr close 2
resultado "vuelve a intentar el suave tras recuperarse" "$(cuenta RESTART_SUAVE)" 2

echo "=== 6. logout (device_removed): NO se reinicia nada ==="
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
echo '{"disconnectionReasonCode":401,"disconnectionObject":{"error":"device_removed"},"disconnectionAt":"2026-08-24T13:21:55.677Z"}' > "$FICHA_FALSA"
ENFRIAMIENTO=0 correr close 6
resultado "restart suave" "$(cuenta RESTART_SUAVE)" 0
resultado "restart contenedor" "$(cuenta RESTART_CONTENEDOR)" 0
resultado "avisos de Telegram (uno solo)" "$(cuenta TELEGRAM)" 1

echo "=== 7. tras un logout, el numero pasa a 'connecting' esperando el escaneo:"
echo "       NO se le puede reiniciar o se le tumba el QR en las manos ==="
# El fallo real del 31-Ago-2026. Secuencia exacta: se cierra la sesion desde el
# movil (close + 401), alguien abre la pagina de vinculacion, eso pide un QR y
# la instancia pasa a "connecting"... y ahi el vigilante la daba por atascada.
# Ojo: este numero SI tiene ownerJid, por eso la comprobacion de "sin vincular"
# no lo protegia. El codigo viejo reinicia aqui; el nuevo no.
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
echo '{"ownerJid":"554197551818@s.whatsapp.net","disconnectionReasonCode":401,"disconnectionObject":{"error":"device_removed"},"disconnectionAt":"2026-08-31T16:04:34.353Z"}' > "$FICHA_FALSA"
ENFRIAMIENTO=0 correr close 3          # se detecta el logout
: > "$ACCIONES"
ENFRIAMIENTO=0 correr connecting 8     # la pagina pide el QR
resultado "restart suave" "$(cuenta RESTART_SUAVE)" 0
resultado "restart contenedor mientras espera el escaneo" "$(cuenta RESTART_CONTENEDOR)" 0

echo "=== 7b. CONTROL: una vez reconectado, un 'connecting' atascado SI se reinicia ==="
# Sin este control, la comprobacion 7 se aprobaria tambien dejando al vigilante
# inerte para siempre. Ademas prueba que los campos 401 de la ficha, que son
# HISTORICOS y no se borran al reconectar, no lo bloquean de por vida.
: > "$ACCIONES"; rm -f "$STATE_DIR"/*
ENFRIAMIENTO=0 correr close 3
correr open 1                          # vuelve a estar conectado
: > "$ACCIONES"
ENFRIAMIENTO=0 correr connecting 8
resultado "restart contenedor" "$(cuenta RESTART_CONTENEDOR)" 1
echo '{}' > "$FICHA_FALSA"

echo
[ "$FALLOS" -eq 0 ] && echo "VEREDICTO: todo correcto" || echo "VEREDICTO: $FALLOS comprobaciones MAL"
rm -rf "$BANCO"
exit "$FALLOS"
