# CRM WhatsApp self-hosted — MVP de 2 números

Stack: **Evolution API (un contenedor por número) + Chatwoot + PostgreSQL + Redis + Traefik**, todo
en Docker Compose sobre un único VPS. Cada número tiene su propia sesión, su propio proxy 4G, su
propia base de datos y su propio proceso: **reiniciar uno no toca al otro**.

> Estado: esqueleto de infraestructura listo para desplegar. Los ficheros están validados
> sintácticamente (YAML y shell), pero el arranque real con los 2 números se hace en el VPS
> durante la Fase 1 — es donde se escanean los QR y se comprueba la salida por proxy 4G.

---

## Qué hay aquí

```
docker-compose.yml          la plataforma entera
.env.example                dominios, claves, proxies  -> copiar a .env
.env.chatwoot.example       config del CRM             -> copiar a .env.chatwoot
postgres-init/              crea una base de datos por número
scripts/provision.sh        alta de un número: instancia + proxy + Chatwoot + QR
scripts/watchdog.sh         vigila las sesiones y escala la reconexión sola
scripts/status.sh           estado de los números + IP real de cada proxy
scripts/backup.sh           copia de bases y de credenciales de sesión
scripts/add-number.sh       genera el bloque para el número 3, 4, 5...
docs/ARQUITECTURA.md        por qué este stack y cómo se aísla cada número
docs/RUNBOOK.md             qué hacer cuando algo se cae (para el equipo)
docs/PROXIES-Y-CALENTAMIENTO.md  elegir proxy 4G + cómo operar los números
```

---

## Requisitos

| Cosa | Detalle |
|---|---|
| VPS | 4 vCPU / 8 GB RAM / 80 GB SSD, Ubuntu 22.04 o 24.04, Docker + Compose v2 |
| Dominio | 3 subdominios con registro A al VPS: `crm.`, `wa1.`, `wa2.` |
| Proxies | 2 proxies 4G **dedicados** (no rotativos), HTTP o SOCKS5, con usuario/contraseña |
| Números | 2 líneas de WhatsApp que **no** estén ya en la API oficial |
| SMTP | Cualquiera (invitaciones de agentes de Chatwoot) |

> Los proxies **rotativos no sirven**: si la IP cambia a mitad de sesión, WhatsApp lo lee como
> secuestro de sesión. Tienen que ser IP fija por número, o sticky de larga duración.

---

## Puesta en marcha

```bash
cp .env.example .env                    # dominios, claves, proxies
cp .env.chatwoot.example .env.chatwoot  # SECRET_KEY_BASE: openssl rand -hex 64
chmod +x scripts/*.sh

docker compose up -d postgres redis
make cw-prepare                         # prepara la base de Chatwoot (solo la 1ª vez)
docker compose up -d                    # todo lo demás

# crear el usuario admin del CRM en https://crm.tudominio.com
# luego: Ajustes > Perfil > Access Token  -> pegar en .env como CW_TOKEN
#        y el número de cuenta de la URL   -> CW_ACCOUNT_ID

make qr1     # genera qr-n1.png -> escanear con el número 1
make qr2     # genera qr-n2.png -> escanear con el número 2
make status  # los 2 en "open" y cada uno saliendo por su IP 4G
```

---

## El día a día

```bash
make status          # ¿están los dos conectados? ¿por qué IP sale cada uno?
make restart-n1      # reinicia SOLO el número 1
make logs-n2         # ver qué está pasando en el número 2
make backup          # copia de seguridad
./scripts/add-number.sh 3 wa3.midominio.com ventas3   # escalar
```

Ver `docs/RUNBOOK.md` para el procedimiento completo de caídas y reconexiones.

---

## Aviso importante, sin adornos

Esto es WhatsApp Web (Baileys), **no la API oficial**. Va contra los términos de servicio de
WhatsApp y un número puede acabar bloqueado. El proxy 4G reduce el riesgo de que un bloqueo
arrastre a los demás números, pero **no evita el bloqueo**: la mayoría de bloqueos se disparan por
el comportamiento (volumen alto, mensajes no solicitados, muchos reportes de usuarios), no por la
IP. Detalle y mitigaciones en `docs/ARQUITECTURA.md`.
