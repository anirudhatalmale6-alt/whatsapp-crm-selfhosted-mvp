# Runbook — qué hacer cuando algo falla

Pensado para que lo siga cualquiera con acceso al servidor, sin llamarme.
Regla de oro: **todo se arregla por número. Nunca hay que parar la plataforma entera.**

Servidor: `ssh anirudha@158.69.198.181` · todo vive en `/opt/wacrm`
CRM: https://crm.estaciondemusculacion.com

---

## Paso 0 — siempre, lo primero

```bash
cd /opt/wacrm
make status
```

Salida de un sistema sano: los dos números en `open` y **tres IP distintas**
(el VPS y un 4G por número). Si un número sale por la IP del VPS, su proxy no
está aplicando: ver **caso D**.

---

## Caso A — un número aparece `connecting`

**`connecting` NO es una caída.** Es el estado normal mientras el motor negocia
con WhatsApp. Tarda segundos, y tras un reinicio puede tardar un poco más.

**No hagas nada durante los primeros minutos.** El vigilante tampoco: le da 5
comprobaciones de margen antes de considerarlo atascado.

> ⚠️ **Nunca lances `/instance/restart` sobre una instancia en `connecting`.**
> Aborta el saludo a medias, el motor abre otro socket sin que muera el
> anterior, y WhatsApp expulsa a uno de los dos con `conflict: replaced`.
> El que queda reintenta, y se entra en una tormenta que se retroalimenta.
> Esto tumbó el número 2 durante una hora el 24-Ago-2026 — y lo provocó el
> propio vigilante, que trataba `connecting` como caída. Ya está corregido,
> pero la trampa sigue ahí si alguien reinicia a mano.

---

## Caso A2 — tormenta de `conflict: replaced`

**Cómo se reconoce:**

```bash
docker logs --since 10m wacrm-evolution-n2 2>&1 | grep -c replaced
```

Sano: `0`, o algún evento suelto. En tormenta: **decenas por minuto** (llegó a 70).
Otra señal: en los logs aparece `Browser: CRM Comercial` una y otra vez cada
medio segundo — son sockets nuevos abriéndose sin parar.

**Cómo se arregla:**

```bash
docker restart wacrm-evolution-n2      # SOLO el contenedor del número afectado
```

El reinicio del contenedor es lo único que se lleva por delante los sockets
huérfanos. Un `/instance/restart` **empeora** la situación.

Después: **no lo toques durante 10 minutos.** Si algo lo vuelve a reiniciar
enseguida, la tormenta vuelve.

---

## Caso B — un número aparece `close` y no vuelve

El vigilante ya escala solo: reconexión suave → reinicio del contenedor → aviso.
Dale unos minutos y mira Telegram.

Si el aviso dice **`se ha cerrado la sesion desde el movil`**, no hay nada que
reiniciar: alguien quitó el dispositivo vinculado, o el teléfono lleva ~14 días
sin abrir WhatsApp. Hace falta **QR nuevo**, por definición del protocolo.

Comprobar el motivo real:

```bash
K=$(grep ^N1_API_KEY /opt/wacrm/.env | cut -d= -f2)
docker exec wacrm-evolution-n1 sh -c \
  "wget -qO- --header=\"apikey: $K\" http://localhost:8080/instance/fetchInstances?instanceName=ventas1"
```

- `disconnectionReasonCode: 401` + `device_removed` → sesión cerrada desde el móvil.
- `conflict / replaced` → caso A2.

> ⚠️ Esos campos son **históricos**: siguen ahí después de reconectar. Lo que
> distingue un cierre nuevo de uno viejo es la fecha (`disconnectionAt`), no su
> mera presencia.

---

## Caso C — volver a vincular un número (QR)

Se hace por la página, no por fichero PNG (un PNG por chat caduca antes de que
lo abran):

```
https://crm.estaciondemusculacion.com/vincular/<VINCULAR_TOKEN>/n1
https://crm.estaciondemusculacion.com/vincular/<VINCULAR_TOKEN>/n2
```

El token está en `/opt/wacrm/.env` (`VINCULAR_TOKEN`). La página refresca el
código sola y detecta la conexión.

**Quien abra esa URL puede enganchar su WhatsApp a la bandeja del cliente.** No
se publica ni se reenvía.

---

## Caso D — un número sale por la IP del VPS en vez de por su 4G

1. Comprobar el proxy directamente (usar los datos de `.env`):
   ```bash
   curl -s --socks5-hostname "USUARIO:CLAVE@HOST:PUERTO" https://api.ipify.org
   ```
   - No responde → problema del proveedor del proxy, no del servidor.
   - Responde con una IP 4G → seguir.
2. Revisar que `N1_PROXY_*` en `.env` están completos y sin espacios sobrantes.
3. Aplicar y reconectar:
   ```bash
   docker compose up -d evolution-n1
   ./scripts/provision.sh n1
   make status
   ```

**Un número, un cambio, verificar, siguiente.** Nunca los dos a la vez.

> Comprobar un proxy con `curl` NO demuestra que el número salga por él: el
> proxy se aplica dentro del socket de Baileys. La prueba de verdad es mirar
> los destinos TCP establecidos del contenedor:
> ```bash
> docker exec wacrm-evolution-n1 sh -c "cat /proc/net/tcp /proc/net/tcp6" | awk '$4=="01"'
> ```

> Que la IP de un proxy 4G **cambie dentro de la misma red del operador es
> normal** y no se avisa a propósito. Lo que sí importa es que cambie de red.

---

## Caso E — el CRM no carga

```bash
docker compose ps
docker compose logs --tail=100 chatwoot
docker compose restart chatwoot chatwoot-worker
```

Los números **siguen conectados** aunque Chatwoot esté caído: Evolution
reintenta los webhooks y los mensajes entran cuando el CRM vuelve.

---

## Caso F — el número está `open` pero no entran mensajes

Es la integración con Chatwoot, no la sesión.

```bash
K=$(grep ^N1_API_KEY /opt/wacrm/.env | cut -d= -f2)
docker exec wacrm-evolution-n1 sh -c \
  "wget -qO- --header=\"apikey: $K\" http://localhost:8080/chatwoot/find/ventas1"
```

Si sale `enabled: false` o vacío → `./scripts/provision.sh n1`.

---

## Caso F2 — Chatwoot dice "enviado", sin error, y el mensaje NO llega

El caso más traicionero de todos, porque **no hay ningún error en ninguna
pantalla ni en ningún log**. Ocurrió el 31-Ago-2026.

**La causa.** WhatsApp ha cambiado cómo direcciona a las personas. Antes cada
una era su teléfono (`554197196955@s.whatsapp.net`); en las cuentas ya migradas
es una dirección interna nueva (`72568119808140@lid`). Todo lo que **entra**
llega con la dirección nueva. Pero Evolution v2.3.7 guarda el **teléfono** en el
campo `identifier` del contacto de Chatwoot, y ese campo es exactamente el
destino que usa al enviar:

```
chatwoot.service.ts:1337   const chatId = sender?.identifier || sender?.phone_number...
chatwoot.service.ts:652    identifier: phoneNumber      <-- escribe el TELÉFONO
```

El motor acepta el envío al teléfono, responde OK y no da error. El mensaje no
sale. Lo que se manda **desde el móvil** sí llega, porque el móvil ya usa la
dirección nueva. Esa asimetría es la firma del fallo.

**Cómo se reconoce.** Comparar destino y estado de los salientes:

```bash
cd /opt/wacrm && . ./.env
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wacrm-postgres-1 \
  psql -U "$POSTGRES_USER" -d evolution_n1 -c \
  "SELECT \"key\"->>'remoteJid' AS destino, status, count(*)
     FROM \"Message\" WHERE (\"key\"->>'fromMe')::boolean
     GROUP BY 1,2 ORDER BY 1;"
```

Sano: los destinos son `...@lid`. Enfermo: hay destinos `...@s.whatsapp.net`
y **todos** están en `PENDING`.

> ⚠️ **`PENDING` por sí solo NO demuestra que un mensaje no llegara.** Hay
> mensajes entregados que se quedan en `PENDING` en esta tabla. Lo que demuestra
> el fallo es el **destino** (`@s.whatsapp.net` en vez de `@lid`), y en última
> instancia el teléfono de la persona. La prueba buena es mandar el mismo texto
> por las dos direcciones y preguntar cuál llegó.

**Cómo se arregla.**

```bash
/opt/wacrm/scripts/reconciliar-lid.py --simular   # ver qué haría
/opt/wacrm/scripts/reconciliar-lid.py             # aplicarlo
```

Lee del propio motor la equivalencia teléfono ↔ dirección nueva (viene en cada
mensaje entrante, campos `remoteJid` / `remoteJidAlt`) y corrige el `identifier`
de cada contacto de Chatwoot. **Ya se ejecuta solo cada 2 minutos por cron**, así
que normalmente no hay que lanzarlo a mano.

Se sostiene solo: Evolution únicamente reescribe el `identifier` cuando difiere
de `remoteJid` (`chatwoot.service.ts:647`). Al dejarlo igual, esa rama deja de
entrar.

**Lo que este arreglo NO cubre:** una persona que **nunca nos ha escrito**. De
esa no conocemos su dirección nueva, así que un primer mensaje saliente hacia
ella puede fallar en silencio. El script las lista al final como
`sin equivalencia`. En cuanto escriba una vez, queda arreglada sola.

> No se parcheó Evolution a propósito: el fallo vive en un bundle minificado de
> 485 KB (`dist/main.js`). Un parche montado ahí sobreviviría también a las
> actualizaciones, y un bundle viejo sobre una versión nueva rompe cosas peores
> en silencio. Cuando una versión estable de Evolution lo corrija, este script
> dejará de encontrar nada que cambiar y se puede retirar.

---

## Caso G — restaurar una copia de seguridad

Las copias están en `/opt/wacrm/backups`, se hacen **cada noche a las 03:00** y
se guardan 14 días.

> ⚠️ **Lo más importante:** las credenciales de sesión de WhatsApp viven en la
> tabla `Session` de cada base `evolution_nX`, **no en el volumen** (el volumen
> ocupa 8 KB y no sirve de nada). Por eso lo que evita tener que reescanear los
> dos QR es el volcado de PostgreSQL.

**Antes de restaurar nada, comprobar que la copia sirve** (esto no toca
producción, restaura en una base temporal y la borra):

```bash
/opt/wacrm/scripts/probar-restauracion.sh
```

Se ejecuta solo cada lunes a las 04:00. Salida sana: cada tabla con sus filas y
`sesion de WhatsApp presente (NNNN bytes)`.

**Restaurar de verdad** (esto SÍ destruye los datos actuales de esa base):

```bash
cd /opt/wacrm
docker compose stop evolution-n1 chatwoot chatwoot-worker   # parar quien escribe

. ./.env
COPIA=$(ls -1t backups/evolution_n1-*.sql.gz | head -1)     # la más reciente
echo "voy a restaurar: $COPIA"                              # MIRARLO antes de seguir

docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" wacrm-postgres-1 \
  psql -U "$POSTGRES_USER" -d postgres -c \
  'DROP DATABASE "evolution_n1"; CREATE DATABASE "evolution_n1";'

zcat "$COPIA" | docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" wacrm-postgres-1 \
  psql -U "$POSTGRES_USER" -d evolution_n1

docker compose start evolution-n1 chatwoot chatwoot-worker
make status
```

La configuración (`.env`, `.env.chatwoot`, `docker-compose.yml`) está en
`backups/config-*.tar.gz`. **Lleva todas las claves dentro**: tratarlo como un
fichero de contraseñas.

---

## Caso H — WhatsApp ha bloqueado un número

No hay truco técnico que lo revierta.

1. Pedir revisión desde la app del número afectado.
2. **No** reciclar el proxy de ese número para una línea nueva: quema también la nueva.
3. Dar de alta la línea de repuesto con su propio proxy:
   `./scripts/add-number.sh 3 wa3.dominio.com ventas3`
4. Revisar qué se enviaba desde esa línea. El bloqueo casi siempre viene del
   envío, no de la infraestructura.

---

## Caso I — el servidor se ha reiniciado

Todo arranca solo (`restart: unless-stopped`) y las sesiones se recuperan de la
base de datos **sin QR**. Confirmar con `make status`.

---

## El vigilante: qué hace y cómo se ajusta

`scripts/watchdog.sh`, cada 60 s por número:

| Estado | Qué hace |
|---|---|
| `open` | nada, y limpia los contadores |
| `connecting` (< 5 veces seguidas) | **nada**, es normal |
| `connecting` (≥ 5 veces) y el número ya estaba vinculado **y no hay un logout pendiente** | reinicia **el contenedor** (nunca la instancia) |
| `connecting` y el número **nunca** se vinculó | nada: está esperando a que alguien escanee el QR |
| `connecting` **con un logout pendiente** (se cerró la sesión y aún no se ha reescaneado) | **nada**: está esperando el escaneo, y reiniciar invalidaría el QR en las manos de quien lo escanea |

> ⚠️ Esa última fila costó un rato el 31-Ago-2026. Al abrir la página de
> vinculación de un número deslogueado, la página pide un QR y la instancia pasa
> de `close` a **`connecting`** — y el vigilante la daba por atascada y le
> reiniciaba el contenedor, invalidando el código justo mientras el cliente lo
> enfocaba con la cámara. Desde fuera parece que "el QR no funciona".
> La comprobación que ya existía (`ownerJid` vacío = nunca vinculado) **no cubre
> este caso**, porque un número deslogueado conserva su `ownerJid`. Lo que lo
> distingue es el fichero `/state/nX.logout`, que se escribe al detectar el
> cierre y sólo se borra cuando el número vuelve a estar `open`.
| `close` | reconexión suave ×2 → reinicio de contenedor ×2 → aviso URGENTE |
| sesión cerrada desde el móvil | **no reinicia nada**, avisa una sola vez por cierre |

Ajustes por variable de entorno:

- `WATCH_INTERVAL` (60) — cada cuánto comprueba
- `WATCH_GRACIA_CONNECTING` (5) — margen antes de tocar un `connecting`
- `WATCH_ENFRIAMIENTO` (600) — **mínimo entre dos reinicios del mismo número**

> El enfriamiento es lo que impide que un fallo persistente convierta al
> vigilante en una máquina de reiniciar. No lo bajes.

Para comprobar que la lógica sigue siendo correcta tras tocarla, sin servidor:

```bash
./scripts/probar-watchdog.sh scripts/watchdog.sh
```

19 comprobaciones sobre 10 escenarios. Tiene que decir `VEREDICTO: todo correcto`.

---

## Mantenimiento periódico

| Cuándo | Qué |
|---|---|
| Diario 03:00 (cron) | `backup.sh` — copia de las 3 bases + volúmenes + config |
| Lunes 04:00 (cron) | `probar-restauracion.sh` — comprueba que las copias sirven |
| Cada 15 min (cron) | `vigilar-ip-proxy.sh` — avisa si un proxy cambia de red |
| Cada 2 min (cron) | `reconciliar-lid.py --cron` — mantiene las direcciones de envío al día (caso F2). Sólo escribe en `/opt/wacrm/logs/reconciliar-lid.log` cuando cambia algo |

> ⚠️ Ese log va a `/opt/wacrm/logs/`, **no a `/var/log/`**, a propósito: el
> usuario `anirudha` no puede crear ficheros en `/var/log`, y cuando cron no
> puede abrir el destino de un `>>` **no ejecuta el comando en absoluto**. La
> tarea aparece en el syslog como lanzada y no hace nada. Silencioso y
> desconcertante; se perdió un rato en ello. Si añades una tarea nueva, escribe
> el log donde el usuario tenga permiso.
>
> Y para comprobar que una tarea de cron corre de verdad, **no basta con que el
> log esté vacío** — eso significa lo mismo que "no se ha ejecutado nunca".
> Control positivo: romper un registro a propósito y ver si se arregla solo.
> ```bash
> . /opt/wacrm/.env
> CW="https://crm.estaciondemusculacion.com/api/v1/accounts/$CW_ACCOUNT_ID"
> curl -s -X PUT -H "api_access_token: $CW_TOKEN" -H "Content-Type: application/json" \
>   -d '{"identifier":"559181959598@s.whatsapp.net"}' "$CW/contacts/2"
> # esperar 2 minutos: el identifier debe volver solo a 210909033185387@lid
> ```
| Semanal | `make status`; que alguien abra WhatsApp en los dos móviles |
| Mensual | `docker compose pull && docker compose up -d` — **un servicio cada vez** |
| Antes de actualizar | `./scripts/backup.sh`. Fijar versión concreta, nunca `:latest` |

Los avisos van a Telegram (`ALERT_TELEGRAM_TOKEN` / `ALERT_TELEGRAM_CHAT_ID`
en `.env`). Telegram **no** es un webhook genérico: sin `chat_id` la API
responde 400 y el aviso se pierde en silencio.
