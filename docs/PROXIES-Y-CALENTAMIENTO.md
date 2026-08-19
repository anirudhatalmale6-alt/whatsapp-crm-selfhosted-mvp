# Proxies 4G y operación de los números

Dos partes: **cómo elegir el proxy antes de pagarlo** y **cómo operar cada número para no quemarlo**.
La primera hay que leerla antes de contratar nada.

---

# PARTE 1 — Elegir el proxy 4G

## Por qué no te doy un nombre de proveedor y ya

Porque sería venderte humo. La calidad de un proxy 4G no depende de la marca, depende de **en qué
bolsa de IP te toca caer el día que contratas**, y eso cambia por país, por operadora y por semana.
El mismo proveedor puede ser excelente en España y un desastre en México. Un nombre que hoy funciona
puede estar quemado en dos meses porque han metido a 300 clientes de spam en el mismo rango.

Lo que sí te sirve para siempre es saber **qué preguntar y cómo probarlo**. Eso es lo que va aquí.
Cuando tengas 2 o 3 candidatos, me pasas los nombres y te los reviso yo antes de que pagues.

## Los 3 requisitos que son innegociables

Si un proveedor falla en cualquiera de estos, se descarta. No hay conversación.

**1. IP dedicada, no compartida.**
Pregunta literal: *"¿esta IP la está usando algún otro cliente vuestro, ahora o antes?"*
Si la comparten, heredas la reputación de lo que hayan hecho los demás. Es la causa número uno de
que un número entre bloqueado el primer día sin que tú hayas hecho nada.

**2. IP fija, o sticky de mínimo 24 horas y que la rotación la controles tú.**
Muchos proveedores 4G rotan la IP cada X minutos o al llamar a un enlace, porque es lo que quiere el
mercado del scraping. **Para nosotros la rotación es veneno**: si la IP cambia a mitad de sesión,
WhatsApp lo lee como que alguien ha secuestrado la sesión desde otro sitio y la cierra.
Pregunta literal: *"¿la IP cambia sola en algún momento? ¿qué pasa con la IP cuando el módem se
reconecta o se reinicia?"* La segunda parte es la importante y casi nadie la contesta a la primera.

**3. Que sea 4G de verdad, de una operadora real.**
Hay proveedores que venden como "móvil" lo que en realidad son IP de centro de datos. Eso es peor
que no poner proxy. Se comprueba en 10 segundos, te explico cómo abajo.

## Lo que hay que preguntar además

- **País y operadora.** Lo ideal es que la IP salga del **mismo país que la línea de WhatsApp**. Un
  número +34 saliendo por una IP de Estados Unidos es una incoherencia que se ve desde fuera.
- **Consumo.** Con uso normal y multimedia calcula 1-3 GB al mes por número activo. Cuidado con las
  tarifas baratas con tope bajo: cuando lo pasas, te cortan o te estrangulan la velocidad, y eso se
  traduce en desconexiones.
- **Protocolo y autenticación.** HTTP o SOCKS5 con usuario y contraseña. Si solo ofrecen autenticación
  por lista blanca de IP también vale, pero entonces necesitamos IP fija en el VPS.
- **Cambio de IP si una se marca.** Pregunta: *"si esta IP acaba señalada, ¿me la cambiáis? ¿cuánto
  tarda y cuánto cuesta?"* Si la respuesta es contratar una línea nueva entera, mal proveedor.
- **Prueba antes de pagar.** Si no dan periodo de prueba ni devolución, desconfía. Los buenos lo dan.
- **Soporte.** Vas a necesitarlo alguna vez. Escríbeles una consulta antes de contratar y mide lo
  que tardan en contestar. Eso te dice más que su web.

## Señales de alarma

- "Proxies residenciales rotativos" vendidos como solución para WhatsApp → no lo son.
- Precio muy por debajo del mercado → IP compartida con mucha gente, seguro.
- No te saben decir la operadora.
- Venden "IP ilimitadas" o pools de miles de IP → eso es scraping, no sesiones persistentes.
- Ofrecen la IP "lista para WhatsApp, ya calentada" → no existe tal cosa.

## Cómo probarlo durante el periodo de prueba

Estas 5 pruebas se hacen en 15 minutos y te ahorran meses de dolor. Si quieres me pasas los datos y
las corro yo.

```bash
# datos del proveedor
P="http://USUARIO:CLAVE@HOST:PUERTO"

# 1) responde y qué IP da
curl -x "$P" https://api.ipify.org; echo

# 2) es movil de verdad? el campo "org" debe ser una OPERADORA (Vodafone,
#    Telcel, Movistar, Claro...). Si sale Amazon, OVH, Hetzner, DigitalOcean
#    o cualquier hosting -> es centro de datos disfrazado, DESCARTAR
IP=$(curl -sx "$P" https://api.ipify.org)
curl -s "https://ipinfo.io/$IP/json"

# 3) la IP se mantiene? dejar corriendo 2 horas: TODAS las lineas iguales
for i in $(seq 1 12); do curl -sx "$P" https://api.ipify.org; echo; sleep 600; done

# 4) latencia hasta WhatsApp. por debajo de 0,4s ideal, hasta 0,8s pasable,
#    por encima de 1,5s va a dar desconexiones
curl -x "$P" -o /dev/null -s -w 'conexion: %{time_connect}s  total: %{time_total}s\n' \
  https://web.whatsapp.com

# 5) WhatsApp no lo tiene ya bloqueado? debe devolver 200
curl -x "$P" -o /dev/null -s -w '%{http_code}\n' https://web.whatsapp.com
```

La prueba 3 es la que más candidatos tumba, y es la que casi nadie hace.

## Y una regla que se olvida siempre

**Un proxy por número, para siempre.** No se comparte entre dos líneas, y si un número se quema,
**su proxy se retira con él**. Reciclar la IP de un número bloqueado para una línea nueva es la forma
más rápida de quemar también la nueva.

---

# PARTE 2 — Cómo operar los números

## Aviso previo, para que las cifras se lean bien

WhatsApp **no publica ningún límite** para clientes no oficiales. Cualquiera que te dé un número
exacto ("300 mensajes al día es seguro") se lo está inventando. Lo que va abajo son márgenes
conservadores de operación, pensados para quedarse cómodamente por debajo de donde saltan los
filtros. No son umbrales oficiales.

Y lo más importante: **el volumen no es lo que más pesa**. Lo que dispara un bloqueo, por orden real
de importancia, es:

1. Que la gente pulse "Reportar" o te bloquee. Esto pesa más que todo lo demás junto.
2. Escribir a gente que nunca te escribió primero.
3. Mandar el mismo texto idéntico a mucha gente.
4. Ritmo de robot: 200 mensajes en cinco minutos, o a las 04:00.
5. Cuenta nueva sin historial haciendo cualquiera de lo anterior.

**Tu caso (entrante primero + seguimiento a esos mismos leads) esquiva los puntos 1 y 2 de serie**,
que son los dos que de verdad queman líneas. Por eso te decía que tu perfil es de los buenos.

## Calentamiento, día a día

| Días | Qué hace el número | Techo orientativo |
|---|---|---|
| **Día 0** | Vincular y **no enviar nada**. Dejarlo conectado 24 h | 0 |
| **Días 1-3** | Solo responder a quien escriba. Nada de seguimientos todavía. Conversación normal | ~20-30 conversaciones/día |
| **Días 4-7** | Responder + empezar seguimientos, con textos variados | ~50-60 conversaciones/día |
| **Días 8-14** | Operación casi normal | ~100-150 conversaciones/día |
| **Día 15+** | Régimen normal | ~200-300 conversaciones/día |

Si la línea ya tiene historial real de uso (meses de conversaciones normales), el calentamiento se
puede acortar a 3-4 días. Si es una SIM recién activada, no lo acortes: es tirar el número.

## Reglas de operación para tu equipo

**Los seguimientos, variados.** Es la regla que más importa en tu caso concreto. Cien seguimientos
idénticos copiados y pegados es un patrón que se detecta solo, aunque todos vayan a gente que os
escribió primero. Chatwoot tiene respuestas guardadas y están muy bien para no repetir trabajo, pero
que el comercial las adapte: el nombre, la referencia a lo que hablaron, algo. Dos frases cambiadas
ya rompen el patrón.

**Ritmo humano.** Nada de vaciar la cola de seguimientos de golpe a las 09:00. Repartido a lo largo
de la jornada, que es como se comporta un comercial de verdad. En horario laboral, no de madrugada.

**Enlaces con cabeza.** En los primeros 15 días de una línea, evitad meter enlaces en el primer
mensaje de una conversación. Después ya sin problema. Y siempre el mismo dominio vuestro, nunca
acortadores tipo bit.ly: los acortadores están muy asociados a spam.

**El mismo archivo a mucha gente, no.** Si tenéis que mandar el mismo catálogo a 50 leads, que no
salga el fichero idéntico en ráfaga. Repartidlo en el tiempo.

**Nada de grupos ni difusión.** Las listas de difusión son de lo que más quema. La plataforma ya va
configurada para ignorar grupos.

**La SIM, viva.** El teléfono con la tarjeta hay que encenderlo de vez en cuando, con datos. Si pasa
más de 14 días apagado, WhatsApp cierra la sesión vinculada y toca reescanear el QR.

## Cómo se ve que un número va camino de quemarse

Vigilad estas tres señales. Si aparecen, bajad el volumen de ESE número a la mitad durante 3-4 días
antes de que sea tarde:

1. Empiezan a aparecer mensajes que se quedan en un check y no llegan al segundo.
2. Sube el número de gente que os bloquea o deja de contestar de golpe.
3. La sesión se desconecta sola varias veces al día sin motivo de red (el vigilante os avisa, y en
   `make status` se ve que el proxy está bien pero la sesión no se sostiene).

La tercera es la más clara: proxy sano y sesión que no aguanta suele significar que WhatsApp está
apretando esa cuenta.

## Reparto entre los 2 números

Sugerencia, con lo que me cuentas del uso: repartid los leads entrantes entre los dos números de
forma equilibrada, en vez de saturar uno y dejar el otro de reserva. Dos razones: la carga repartida
es más segura para ambos, y así los dos tienen historial real de uso, con lo que si uno cae el otro
ya está caliente y puede absorber el trabajo desde el primer minuto. Un número "de reserva" que
nunca se usa es exactamente un número frío, o sea el más frágil justo el día que lo necesitáis.

---

## Qué hago yo de todo esto

- Reviso los proveedores que preselecciones **antes** de que pagues.
- Corro las 5 pruebas sobre los proxies de prueba y te digo si valen o no.
- Dejo el calendario de calentamiento adaptado a vuestras 2 líneas concretas, según sean nuevas o
  con historial.
- Traduzco estas reglas a algo que el equipo comercial pueda seguir sin leerse este documento.
