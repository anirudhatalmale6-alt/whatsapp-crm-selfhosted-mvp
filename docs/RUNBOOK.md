# Runbook — qué hacer cuando algo falla

Pensado para que lo siga cualquiera del equipo técnico, sin llamarme.
Regla de oro: **todo se arregla por número. Nunca hay que parar la plataforma entera.**

---

## Paso 0 — siempre, lo primero

```bash
cd /opt/wacrm
make status
```

Salida de un sistema sano:

```
 NUMEROS
  N1  ventas1      -> open
  N2  ventas2      -> open
 PROXIES 4G
  VPS      : 203.0.113.10
  N1       : 100.64.11.7    (proxy1.proveedor.com:9001)
  N2       : 100.64.44.2    (proxy2.proveedor.com:9002)
```

Las tres IP tienen que ser **distintas entre sí**. Si un número sale por la IP del VPS, el proxy no
está aplicando: ver caso D.

---

## Caso A — un número aparece `close` o `connecting`

El vigilante ya lo está intentando solo. Dale 2–3 minutos y vuelve a `make status`.

Si sigue caído:

```bash
make logs-n1              # ¿qué dice? (Ctrl-C para salir)
make restart-n1           # reinicio solo de ese número
```

El otro número **no se toca y sigue atendiendo**. Si tras el reinicio vuelve a `open`, listo: no
hace falta QR.

---

## Caso B — sigue caído después de reiniciar → hace falta QR

WhatsApp ha cerrado la sesión desde su lado (bloqueo, cierre manual desde el móvil, o el teléfono
más de 14 días apagado).

```bash
make qr1                  # genera qr-n1.png
```

Abrir `qr-n1.png` y escanear desde el móvil de esa línea:
**WhatsApp → Ajustes → Dispositivos vinculados → Vincular un dispositivo**.

El QR caduca en ~40 s; si expira, `make qr1` otra vez. Confirmar con `make status`.

> Mientras tanto el otro número no se entera en ningún momento.

---

## Caso C — el CRM no carga (crm.dominio.com)

```bash
docker compose ps                       # ¿chatwoot y chatwoot-worker "Up"?
docker compose logs --tail=100 chatwoot
docker compose restart chatwoot chatwoot-worker
```

Los números **siguen conectados** aunque Chatwoot esté caído: Evolution reintenta los webhooks y
los mensajes entran cuando el CRM vuelve. No hay pérdida.

---

## Caso D — un número sale por la IP del VPS en vez de por su 4G

1. Comprobar el proxy directamente:
   ```bash
   curl -x http://USUARIO:CLAVE@HOST:PUERTO https://api.ipify.org
   ```
   - No responde → problema del proveedor del proxy, no del servidor.
   - Responde con la IP 4G → seguir.
2. Revisar que `N1_PROXY_*` en `.env` están completos y sin espacios sobrantes.
3. Aplicar y reconectar:
   ```bash
   docker compose up -d evolution-n1     # recarga variables
   ./scripts/provision.sh n1
   make status
   ```

**Importante:** si el proxy de un número cambia de IP, no cambies la del otro a la vez. Un número,
un cambio, verificar, siguiente.

---

## Caso E — el número está `open` pero no entran mensajes en el CRM

Es la integración con Chatwoot, no la sesión.

```bash
curl -H "apikey: $N1_API_KEY" https://wa1.tudominio.com/chatwoot/find/ventas1
```

Si sale `enabled: false` o vacío, reaplicar:

```bash
./scripts/provision.sh n1
```

Comprobar también que en Chatwoot existe la bandeja con ese nombre y que los agentes están
asignados a ella (Ajustes → Bandejas de entrada → Agentes).

---

## Caso F — WhatsApp ha bloqueado un número

No hay truco técnico que lo revierta. Procedimiento:

1. Pedir revisión desde la app del número afectado (a veces se levanta en 24–48 h).
2. **No** reciclar el proxy de ese número para una línea nueva: quema también la nueva.
3. Dar de alta la línea de repuesto con su propio proxy:
   ```bash
   ./scripts/add-number.sh 3 wa3.tudominio.com ventas3
   ```
4. Revisar qué se estaba enviando desde esa línea antes del bloqueo. El bloqueo casi siempre es
   consecuencia del envío, no de la infraestructura (ver `ARQUITECTURA.md`, punto 5).

---

## Caso G — el servidor se ha reiniciado

Todo arranca solo (`restart: unless-stopped`) y las sesiones se recuperan de la base de datos
**sin QR**. Sólo confirmar:

```bash
make status
```

---

## Mantenimiento periódico

| Cuándo | Qué |
|---|---|
| Diario 03:00 (cron) | `./scripts/backup.sh` |
| Semanal | `make status` y ojo a la RAM (`docker stats --no-stream`) |
| Mensual | `docker compose pull && docker compose up -d` — **un servicio cada vez**, verificando entre uno y otro |
| Antes de actualizar | `./scripts/backup.sh`. Y fijar siempre versión concreta, nunca `:latest` |
