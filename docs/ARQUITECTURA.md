# Arquitectura y decisiones

## 1. Qué stack y por qué

**Evolution API (un contenedor por número) + Chatwoot.** Es la opción que planteabas, y coincido,
pero con un matiz importante en el "cómo" (ver punto 2).

Por qué cada pieza, y por qué no las alternativas:

| Pieza | Papel | Alternativa descartada y motivo |
|---|---|---|
| **Evolution API** | motor de WhatsApp Web (Baileys). Multi-instancia, proxy por instancia, integración nativa con Chatwoot, API REST clara | **WPPConnect**: sólido, pero arrastra un Chromium por sesión → mucha más RAM y más frágil ante reinicios. Baileys habla el protocolo directamente, sin navegador |
| **Chatwoot** | la bandeja del equipo: etiquetas, asignación, equipos, notas privadas, respuestas guardadas, audio/imagen/documento, buscador, informes | **Whaticket**: todo-en-uno y rápido de montar, pero es un proyecto con muchos forks de calidad desigual y el CRM es más pobre. Chatwoot tiene empresa detrás, releases regulares y separa motor de bandeja — que es justo lo que permite cambiar de motor sin rehacer el CRM |
| **PostgreSQL** | una base **por número** + una para Chatwoot | — |
| **Redis** | caché, un índice por número | — |
| **Traefik** | HTTPS automático (Let's Encrypt) para los 3 subdominios | — |

La decisión de fondo: **motor y bandeja desacoplados**. Si mañana Evolution deja de convenir, se
sustituye el motor y el histórico de conversaciones, las etiquetas y los agentes siguen intactos en
Chatwoot. Con un todo-en-uno tipo Whaticket, cambiar de motor es tirar el CRM.

---

## 2. Cómo se aísla cada número — el punto clave

La forma habitual de montar esto es **un solo contenedor Evolution con dos instancias dentro** y un
proxy configurado por instancia vía `POST /proxy/set/{instancia}`. Funciona, pero tiene dos
problemas reales:

1. **Fallo compartido.** Un proceso, dos sesiones. Si el contenedor se cae, se queda sin memoria o
   hay que reiniciarlo para aplicar un cambio, **caen los dos números a la vez**. Justo lo que
   pides evitar.
2. **El proxy por instancia ha ido dando guerra.** En las versiones recientes de Evolution la
   validación del proxy ha tenido regresiones — hay un fallo abierto en el repositorio
   (`evolution-foundation/evolution-api#2054`) sobre `/proxy/set` rechazando proxies válidos con
   *"testProxy error"* a partir de la v2.3.4. Depender sólo de ese endpoint es apoyar el
   aislamiento en la parte más inestable del sistema.

**Lo que hago en su lugar: un contenedor Evolution por número.**

```
                        ┌──────────── Traefik (HTTPS) ────────────┐
                        │                                          │
        crm.dominio ────┤                                          │
                        ▼                                          ▼
                 ┌─────────────┐                        ┌──────────────────┐
                 │  Chatwoot   │◀── webhooks ──────────▶│ evolution-n1     │──▶ proxy 4G #1 ──▶ WA
                 │  (bandeja)  │                        │ BD evolution_n1  │
                 │             │                        │ redis/1 · vol n1 │
                 │  bandeja 1  │                        └──────────────────┘
                 │  bandeja 2  │                        ┌──────────────────┐
                 └─────────────┘◀── webhooks ──────────▶│ evolution-n2     │──▶ proxy 4G #2 ──▶ WA
                        │                               │ BD evolution_n2  │
                        ▼                               │ redis/2 · vol n2 │
                 PostgreSQL · Redis                     └──────────────────┘
                 (red interna, sin salida a internet)
```

Cada número queda separado en **cinco capas**:

| Capa | Aislamiento |
|---|---|
| Proceso | contenedor propio. Si uno se cuelga o se reinicia, el otro ni se entera |
| Red de salida | `PROXY_HOST/PORT/PROTOCOL/USERNAME/PASSWORD` a nivel de contenedor → **todo** el tráfico de WhatsApp de ese número sale por su 4G. No depende del endpoint `/proxy/set` |
| Datos | base de datos propia (`evolution_n1` / `evolution_n2`) |
| Caché | índice Redis propio (`/1`, `/2`) + prefijo de clave propio |
| Sesión | volumen propio (`/evolution/instances`) con las credenciales del dispositivo vinculado |
| Credencial | API key propia: quien tenga la del número 1 no puede tocar el 2 |

El proxy además se fija **también** por instancia en `provision.sh` (doble cinturón), pero el
aislamiento no depende de que eso funcione.

Coste de esta decisión: ~250–400 MB de RAM extra por número frente al contenedor único. Con 8 GB
sobra de largo para 2 números y hay margen hasta unos 8–10.

---

## 3. Persistencia de sesión

Las credenciales del dispositivo vinculado viven en la base de datos de cada número
(`DATABASE_SAVE_DATA_INSTANCE=true`) y en su volumen. Consecuencias prácticas:

- `docker compose restart evolution-n1` → reconecta solo, **sin QR**.
- `docker compose down && up` → reconecta solo, **sin QR**.
- Actualizar la imagen de Evolution → reconecta solo, **sin QR**.
- Sólo hace falta reescanear si WhatsApp cierra la sesión desde el otro lado (bloqueo, cierre
  manual desde el móvil, o >14 días con el teléfono apagado).

`backup.sh` copia bases y volúmenes: se puede reconstruir el servidor entero sin volver a escanear.

---

## 4. Caídas: qué pasa cuando un número se desconecta

Hay un contenedor vigilante que pregunta a cada número por su estado cada 60 s y escala solo,
**siempre por número, nunca global**:

| Fallos seguidos | Acción | Impacto en el otro número |
|---|---|---|
| 1–2 | `POST /instance/restart` — reconexión suave, sin QR | ninguno |
| 3–4 | `docker restart` de **ese** contenedor (~15 s) | ninguno |
| 5 | Aviso al webhook (Telegram/Slack): "hay que reescanear el QR" | ninguno |
| vuelve a `open` | Aviso de recuperación y contador a cero | ninguno |

Además cada contenedor lleva `healthcheck` y `restart: unless-stopped`, con lo que Docker levanta
por su cuenta lo que se muera, sin tocar a los vecinos. Mientras el número 1 reconecta, los agentes
siguen atendiendo el número 2 en la misma pantalla de Chatwoot; los mensajes entrantes del número
caído se entregan en cuanto vuelve (WhatsApp los guarda del lado del servidor).

El procedimiento manual, escrito para que lo ejecute vuestro equipo sin mí, está en `RUNBOOK.md`.

---

## 5. Lo que hay que saber antes de empezar (aviso honesto)

Esto es WhatsApp Web no oficial. Va contra los términos de servicio de WhatsApp y **un número puede
acabar bloqueado**. Ningún montaje evita eso, y quien diga lo contrario no está siendo honesto.

Lo que este diseño sí consigue:

- Que un bloqueo quede **contenido en un número**, sin arrastrar a los demás.
- Que cada línea tenga huella de red propia y estable (IP 4G residencial fija, no datacenter).
- Que reponer un número sea escanear un QR, no rehacer el servidor.

Lo que **no** consigue, y conviene tener claro: la mayoría de bloqueos no vienen de la IP, vienen
del comportamiento — volumen alto en poco tiempo, mensajes a gente que no os escribió primero,
plantillas idénticas repetidas y, sobre todo, que la gente pulse "Reportar". Si el problema actual
con la API oficial son restricciones por calidad de envío, cambiar de canal traslada el problema,
no lo resuelve.

Mitigaciones que sí mueven la aguja, y que van incluidas en la puesta en marcha:

- Calentar cada número: días de conversación normal antes de meterlo en producción.
- Números con historial real, nunca SIM recién activada enviando 200 mensajes el primer día.
- `groupsIgnore=true` y `alwaysOnline=false`: perfil de uso parecido al de una persona.
- Responder principalmente a quien escribe primero; el saliente masivo es lo que quema líneas.
- `SESSION_PHONE_CLIENT` coherente y estable, no cambiándolo en cada arranque.

---

## 6. Escalado

Añadir un número más = un bloque de compose + 5 variables + una base de datos. `add-number.sh` lo
genera hecho. Sin rediseño, sin tocar lo que ya funciona.

Referencia de capacidad en el mismo VPS de 8 GB: 2 números holgado, hasta ~8 cómodo. A partir de
ahí lo lógico es separar Chatwoot y Postgres a su propia máquina y dejar el VPS para motores.
