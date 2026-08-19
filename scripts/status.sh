#!/usr/bin/env bash
# Foto rapida: que numero esta conectado, por que IP sale cada uno y como
# esta la plataforma. Es lo primero que hay que mirar cuando algo falla.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

line() { printf '%s\n' "-------------------------------------------------------------"; }

line; echo " CONTENEDORES"; line
docker compose ps --format 'table {{.Service}}\t{{.Status}}'

line; echo " NUMEROS"; line
for n in n1 n2; do
  UP=$(echo "$n" | tr '[:lower:]' '[:upper:]')
  h="${UP}_HOST";  k="${UP}_API_KEY";  i="${UP}_INSTANCE"
  st=$(curl -sS --max-time 15 -H "apikey: ${!k}" \
        "https://${!h}/instance/connectionState/${!i}" 2>/dev/null \
        | grep -o '"state":"[a-z]*"' | cut -d'"' -f4)
  printf '  %-3s %-12s -> %s\n' "$UP" "${!i}" "${st:-sin respuesta}"
done

line; echo " PROXIES 4G (cada numero debe salir por una IP distinta y != VPS)"; line
echo "  VPS      : $(curl -sS --max-time 10 https://api.ipify.org 2>/dev/null)"
for n in n1 n2; do
  UP=$(echo "$n" | tr '[:lower:]' '[:upper:]')
  ph="${UP}_PROXY_HOST"; pp="${UP}_PROXY_PORT"; pr="${UP}_PROXY_PROTOCOL"
  pu="${UP}_PROXY_USERNAME"; pw="${UP}_PROXY_PASSWORD"
  if [[ -z "${!ph:-}" ]]; then printf '  %-8s : sin proxy configurado\n' "$UP"; continue; fi
  auth=""; [[ -n "${!pu:-}" ]] && auth="${!pu}:${!pw}@"
  ip=$(curl -sS --max-time 20 -x "${!pr}://${auth}${!ph}:${!pp}" \
        https://api.ipify.org 2>/dev/null)
  printf '  %-8s : %s   (%s:%s)\n' "$UP" "${ip:-PROXY NO RESPONDE}" "${!ph}" "${!pp}"
done
echo "  nota: esto prueba el proxy en si. La IP con la que WhatsApp ve la"
echo "        sesion se confirma en el movil: WhatsApp > Dispositivos vinculados."
line
