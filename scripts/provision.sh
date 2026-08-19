#!/usr/bin/env bash
# =============================================================================
#  Da de alta UN numero: crea la instancia, le fija su proxy, la enchufa a
#  Chatwoot y muestra el QR para escanear.
#
#  Uso:   ./scripts/provision.sh n1
#         ./scripts/provision.sh n2
#
#  Es idempotente: si la instancia ya existe no la borra, solo reaplica proxy
#  y configuracion de Chatwoot.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

N="${1:-}"
[[ "$N" =~ ^n[0-9]+$ ]] || { echo "uso: $0 n1|n2"; exit 1; }

set -a; source .env; set +a
UP="$(echo "$N" | tr '[:lower:]' '[:upper:]')"

host_var="${UP}_HOST";       HOST="${!host_var}"
key_var="${UP}_API_KEY";     KEY="${!key_var}"
inst_var="${UP}_INSTANCE";   INSTANCE="${!inst_var}"
ph_var="${UP}_PROXY_HOST";   P_HOST="${!ph_var:-}"
pp_var="${UP}_PROXY_PORT";   P_PORT="${!pp_var:-}"
pr_var="${UP}_PROXY_PROTOCOL"; P_PROTO="${!pr_var:-http}"
pu_var="${UP}_PROXY_USERNAME"; P_USER="${!pu_var:-}"
pw_var="${UP}_PROXY_PASSWORD"; P_PASS="${!pw_var:-}"

BASE="https://${HOST}"
CURL=(curl -sS --max-time 30 -H "apikey: ${KEY}" -H "Content-Type: application/json")

echo "==> numero ${UP}  |  instancia '${INSTANCE}'  |  ${BASE}"

# ---------------------------------------------------------------- 1. instancia
exists=$("${CURL[@]}" "${BASE}/instance/fetchInstances" \
          | grep -c "\"name\":\"${INSTANCE}\"" || true)

if [[ "$exists" == "0" ]]; then
  echo "--> creando instancia"
  "${CURL[@]}" -X POST "${BASE}/instance/create" -d @- <<JSON | head -c 400; echo
{
  "instanceName": "${INSTANCE}",
  "integration": "WHATSAPP-BAILEYS",
  "qrcode": true,
  "rejectCall": false,
  "groupsIgnore": true,
  "alwaysOnline": false,
  "readMessages": false,
  "readStatus": false,
  "syncFullHistory": false
}
JSON
else
  echo "--> la instancia ya existe, no se toca"
fi

# ------------------------------------------------------------------- 2. proxy
# Doble cinturon: el contenedor YA sale por su proxy (PROXY_* del compose).
# Ademas lo fijamos a nivel de instancia por si se levanta fuera de compose.
if [[ -n "$P_HOST" ]]; then
  echo "--> fijando proxy ${P_PROTO}://${P_HOST}:${P_PORT}"
  "${CURL[@]}" -X POST "${BASE}/proxy/set/${INSTANCE}" -d @- <<JSON | head -c 300; echo
{
  "enabled": true,
  "host": "${P_HOST}",
  "port": "${P_PORT}",
  "protocol": "${P_PROTO}",
  "username": "${P_USER}",
  "password": "${P_PASS}"
}
JSON
else
  echo "!! sin proxy configurado para ${UP} (se saldria por la IP del VPS)"
fi

# ---------------------------------------------------------------- 3. Chatwoot
if [[ -n "${CW_ACCOUNT_ID:-}" && -n "${CW_TOKEN:-}" ]]; then
  echo "--> conectando a Chatwoot (bandeja '${INSTANCE}')"
  "${CURL[@]}" -X POST "${BASE}/chatwoot/set/${INSTANCE}" -d @- <<JSON | head -c 300; echo
{
  "enabled": true,
  "accountId": "${CW_ACCOUNT_ID}",
  "token": "${CW_TOKEN}",
  "url": "https://${CRM_HOST}",
  "signMsg": false,
  "reopenConversation": true,
  "conversationPending": false,
  "nameInbox": "${INSTANCE}",
  "importContacts": false,
  "importMessages": false,
  "autoCreate": true,
  "organization": "${INSTANCE}"
}
JSON
else
  echo "!! CW_ACCOUNT_ID / CW_TOKEN no definidos en .env -> paso de Chatwoot"
fi

# -------------------------------------------------------------------- 4. QR
state=$("${CURL[@]}" "${BASE}/instance/connectionState/${INSTANCE}" || true)
echo "--> estado: ${state}"

if ! grep -q '"state":"open"' <<<"$state"; then
  echo "--> generando QR..."
  "${CURL[@]}" "${BASE}/instance/connect/${INSTANCE}" \
    | python3 -c '
import sys, json, base64, pathlib
d = json.load(sys.stdin)
b64 = (d.get("base64") or "").split(",")[-1]
if b64:
    p = pathlib.Path("qr-'"${N}"'.png"); p.write_bytes(base64.b64decode(b64))
    print("QR guardado en", p.resolve())
if d.get("pairingCode"):
    print("codigo de vinculacion:", d["pairingCode"])
'
  echo "    Escanear desde WhatsApp > Dispositivos vinculados (el QR caduca)."
else
  echo "--> ya conectado, nada que escanear"
fi
