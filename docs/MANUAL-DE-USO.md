# Manual de uso — para ti y tu equipo

Este manual **no** es técnico. Es para la persona que atiende WhatsApp cada día.
Si buscas cómo restaurar una copia o qué hacer cuando algo se rompe, ese es el
[RUNBOOK](RUNBOOK.md).

---

## 1. Qué es esto

Tus dos números de WhatsApp entran en **una sola pantalla**. En vez de dos
teléfonos encima de la mesa, una bandeja de entrada donde ves las
conversaciones de los dos.

- **CRM:** https://crm.estaciondemusculacion.com
- **Bandeja `ventas1`** → todo lo que llega al número 1
- **Bandeja `ventas2`** → todo lo que llega al número 2

Cada mensaje sale por el número al que escribió el cliente. No hay forma de
contestar desde el número equivocado: la bandeja manda.

---

## 2. El día a día

Escribes en la conversación y el cliente lo recibe en su WhatsApp normal. Él
no ve nada raro: para él es una conversación de WhatsApp corriente.

Funciona en los dos sentidos:

| | Entra (cliente → CRM) | Sale (CRM → cliente) |
|---|---|---|
| Texto | sí | sí |
| Nota de voz / audio | sí | sí |
| Foto | sí | sí |
| PDF y documentos | sí | sí |

Todo esto está probado uno por uno en los dos números.

> **Un caso concreto en el que conviene confirmar:** cuando escribes tú primero
> a alguien que **nunca te ha escrito** por WhatsApp. WhatsApp ha cambiado la
> forma de identificar a las personas, y de alguien que no ha escrito nunca el
> sistema todavía no conoce su dirección nueva. Ese primer mensaje puede no
> llegar, y Chatwoot lo daría por enviado igualmente.
>
> En cuanto esa persona te escribe **una sola vez**, queda arreglado solo y ya no
> vuelve a pasar. Así que si abres tú una conversación nueva y no te contestan,
> no des por hecho que te están ignorando: confírmalo por otra vía.
>
> Con quien ya te ha escrito alguna vez esto no ocurre.

---

## 3. Tres reglas que hay que respetar

### Regla 1 — enciende los dos teléfonos al menos una vez por semana

Los dos móviles dedicados tienen que **abrir WhatsApp de vez en cuando**, con
datos o wifi. No hace falta usarlos: con abrir la app basta.

Si un teléfono pasa **unos 14 días sin conectarse**, WhatsApp corta el
dispositivo vinculado por su cuenta y ese número desaparece del CRM. Recuperarlo
es fácil (se vuelve a escanear un código), pero mientras tanto no entra nada por
ese número.

> Ponlo como recordatorio semanal. Es la causa más común de que un número
> "se caiga solo" sin que nadie haya tocado nada.

### Regla 2 — nunca quites el dispositivo vinculado

En el móvil, **WhatsApp → Dispositivos vinculados**, aparecerá un dispositivo
llamado `CRM Comercial`. **Ese es el CRM. No lo cierres.**

Si alguien le da a "Cerrar sesión" ahí, el número se cae al instante y hay que
volver a vincularlo. Tampoco se debe tocar "Eliminar mi cuenta" en ese teléfono.

El 24 de agosto pasó exactamente esto con el número 1: alguien quitó el
dispositivo vinculado desde el móvil y el número se cayó. No fue un fallo del
sistema.

### Regla 3 — si sale "Error al enviar" en una foto grande, NO reintentes enseguida

Esto lo descubriste tú y es importante.

Cuando mandas una foto pesada (2 MB o más), el CRM se la pasa al motor de
WhatsApp y espera respuesta. Si el motor tarda, **el CRM se cansa de esperar y
pinta "Error al enviar"** — pero por detrás el envío casi siempre termina bien.

**Qué hacer:** esperar unos segundos. El estado se corrige solo, o preguntas al
cliente si le llegó.

**Qué NO hacer:** darle al botón de reintentar una y otra vez. Como el envío sí
salió, **el cliente recibe la foto dos o tres veces**.

---

## 4. Los avisos de Telegram

Tienes un bot (`avisoswhatsappbot`) que te escribe cuando algo pasa. Qué
significa cada aviso:

| Aviso | Qué significa | Qué haces tú |
|---|---|---|
| `AVISO: nX desconectado. Reconexion suave lanzada` | Un número se ha caído y el sistema ya lo está recuperando | Nada. Esperar. |
| `AVISO: se ha quedado atascado conectando` | No se recuperaba solo, se reinicia su motor | Nada. Esperar 2 minutos. |
| `OK: el numero nX volvio a estar conectado` | Ya está resuelto | Nada |
| `URGENTE: se ha cerrado la sesion desde el movil` | Alguien quitó el dispositivo vinculado (Regla 2) | Hay que volver a vincular — sección 5 |
| `URGENTE: nX sigue caido despues de...` | No se ha podido arreglar solo | Avísame |
| `URGENTE: la copia de seguridad ha fallado` | La copia de esta noche no salió bien | Avísame |

**Muy importante:** los avisos de "desconectado / reconectando" son **normales
de vez en cuando**. Una caída puntual que se recupera sola no es un problema.
Preocúpate cuando veas los `URGENTE`.

Lo que **no** genera aviso a propósito: que el proxy 4G cambie de IP dentro de
la misma red del operador. Eso pasa constantemente y es normal.

---

## 5. Volver a vincular un número

Si un número se cayó del todo (Regla 1 o Regla 2), se arregla en un minuto:

1. Abre en el navegador el enlace del número que se cayó
   (te los pasé por chat, son largos y llevan un token secreto):
   - número 1 → `/vincular/<token>/n1`
   - número 2 → `/vincular/<token>/n2`
2. Coge **el móvil de ese número** (no otro).
3. WhatsApp → **Dispositivos vinculados** → **Vincular un dispositivo**.
4. Apunta la cámara al código de la pantalla.

La página se refresca sola: **no hace falta recargarla**. Cuando termina, ella
misma te dice "Número conectado correctamente".

**La página te dice siempre qué está pasando:**

- *"Número conectado correctamente"* → ya está, cierra la página.
- *"Este número está reconectándose solo"* → **no escanees nada**, espera.
- *"Ahora mismo no hay código que escanear"* → ese número ya está vinculado,
  no hay nada que hacer.

> Cuidado: esos enlaces son secretos. Quien los abra puede enganchar **su**
> WhatsApp a tu bandeja. No los publiques ni los reenvíes.

---

## 6. Lo que este sistema NO hace

Para que no haya sorpresas:

- **No hay bots ni respuestas automáticas.** Contesta una persona.
- **No manda campañas ni mensajes masivos.** Es para conversar, no para
  difusión. Usar esto para enviar masivamente es la mejor forma de que
  WhatsApp bloquee el número.
- **No es la API oficial de Meta.** Es WhatsApp normal con dispositivos
  vinculados. Funciona bien, pero WhatsApp no lo garantiza por contrato.
- **Los dos números están aislados técnicamente**, cada uno con su proxy, su
  sesión y su base de datos: si uno se cae, el otro sigue trabajando. Eso está
  comprobado. Lo que **no** puede evitar ningún sistema es que WhatsApp
  relacione dos números por cómo se comportan (mismos textos, mismos horarios,
  mismos contactos). El aislamiento es técnico, no de comportamiento.

---

## 7. Cuándo avisarme

- Cualquier aviso `URGENTE` de Telegram que no se resuelva solo.
- Un número que lleva más de 10 minutos caído.
- Mensajes que no entran aunque el número aparezca conectado.
- **Mensajes que Chatwoot da por enviados y el cliente dice que no le llegaron.**
  Es un fallo real y silencioso, no un despiste del cliente. Dime a quién y
  cuándo, que se comprueba en dos minutos.
- WhatsApp ha bloqueado un número.
