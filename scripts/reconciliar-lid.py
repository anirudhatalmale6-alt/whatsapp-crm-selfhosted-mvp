#!/usr/bin/env python3
"""
reconciliar-lid.py — que los mensajes que salen de Chatwoot lleguen de verdad.

EL PROBLEMA
-----------
WhatsApp ha cambiado la forma de direccionar a las personas. Antes cada una era
su numero de telefono (`5541...@s.whatsapp.net`). Ahora, en las cuentas ya
migradas, es una direccion interna nueva (`72568119808140@lid`).

Todo lo que ENTRA llega con la direccion nueva. Pero cuando Chatwoot manda un
mensaje, Evolution usa como destino el campo `identifier` del contacto de
Chatwoot — y Evolution v2.3.7 guarda ahi el telefono, a proposito:

    chatwoot.service.ts:1337   const chatId = sender?.identifier || sender?.phone_number...
    chatwoot.service.ts:652    identifier: phoneNumber   <-- escribe el TELEFONO

El motor acepta el envio al telefono, responde OK y NO da ningun error, pero el
mensaje no llega nunca. Fallo silencioso: en Chatwoot se ve "enviado".

Comprobado el 31-Ago-2026 sobre los 27 envios del numero 1: los 12 que salieron
por la direccion nueva constan entregados; los 15 que salieron por el telefono,
ninguno. 27 de 27, sin excepcion. Y confirmado por el cliente en su telefono con
dos mensajes de prueba identicos, uno por cada direccion.

LA SOLUCION
-----------
El propio motor guarda la equivalencia en cada mensaje entrante:

    "remoteJid":    "72568119808140@lid"            <- direccion nueva
    "remoteJidAlt": "554197196955@s.whatsapp.net"   <- telefono

Este script lee esos pares y pone la direccion NUEVA en el `identifier` del
contacto de Chatwoot. A partir de ahi los envios salen bien.

Y ademas se sostiene solo: Evolution solo reescribe el identifier cuando
`contact.identifier !== remoteJid` (chatwoot.service.ts:647). Al dejarlo igual a
remoteJid, esa rama deja de entrar y ya no lo vuelve a estropear.

POR QUE ESTO Y NO PARCHEAR EVOLUTION
------------------------------------
El fallo esta en un bundle minificado de 485 KB (`dist/main.js`). Un parche ahi
sobrevive a los reinicios pero tambien sobrevive a las ACTUALIZACIONES, y un
bundle viejo montado encima de una version nueva rompe cosas peores en silencio.
Esto no toca el codigo del motor: si una version futura lo arregla, este script
deja de encontrar nada que cambiar y se puede quitar sin mas.

USO
---
    ./reconciliar-lid.py --simular    # dice que haria, sin tocar nada
    ./reconciliar-lid.py              # lo aplica y verifica leyendo de vuelta
    ./reconciliar-lid.py --cron       # igual, pero callado si no hubo nada que hacer
"""

import json
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
BASES = {"evolution_n1": "n1", "evolution_n2": "n2"}
CONTENEDOR_PG = "wacrm-postgres-1"

CONSULTA_PARES = """
SELECT DISTINCT
       "key"->>'remoteJid'    AS lid,
       "key"->>'remoteJidAlt' AS telefono
FROM "Message"
WHERE "key"->>'remoteJid'    LIKE '%@lid'
  AND "key"->>'remoteJidAlt' LIKE '%@s.whatsapp.net';
"""


def entorno():
    """Lee el .env sin arrastrar la sintaxis de bash."""
    datos = {}
    fichero = DIR / ".env"
    if not fichero.exists():
        salir(f"no encuentro {fichero}")
    for linea in fichero.read_text().splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, valor = linea.split("=", 1)
        datos[clave.strip()] = valor.strip().strip("'\"")
    return datos


SALIDA = []


def di(linea=""):
    """Acumula en vez de imprimir: en modo --cron solo se vuelca si hubo algo."""
    SALIDA.append(linea)


def salir(mensaje):
    # Un fallo se cuenta siempre, aunque estemos en modo callado.
    for linea in SALIDA:
        print(linea)
    print(f"!! {mensaje}", file=sys.stderr)
    sys.exit(1)


def pares_conocidos(env):
    """{telefono_en_digitos: direccion_lid} segun lo que ha visto el motor."""
    mapa = {}
    for base in BASES:
        orden = [
            "docker", "exec", "-i",
            "-e", f"PGPASSWORD={env['POSTGRES_PASSWORD']}",
            CONTENEDOR_PG,
            "psql", "-A", "-t", "-F", "\t", "-q",
            "-U", env["POSTGRES_USER"], "-d", base, "-f", "-",
        ]
        try:
            res = subprocess.run(
                orden, input=CONSULTA_PARES, capture_output=True, text=True, timeout=60
            )
        except subprocess.TimeoutExpired:
            salir(f"la consulta a {base} no respondio")
        if res.returncode != 0:
            salir(f"psql fallo en {base}: {res.stderr.strip()}")
        for linea in res.stdout.splitlines():
            if "\t" not in linea:
                continue
            lid, telefono = linea.split("\t", 1)
            lid, telefono = lid.strip(), telefono.strip()
            if lid and telefono:
                mapa[telefono.split("@")[0]] = lid
    return mapa


class Chatwoot:
    def __init__(self, env):
        self.base = f"https://crm.estaciondemusculacion.com/api/v1/accounts/{env['CW_ACCOUNT_ID']}"
        self.cabeceras = {
            "api_access_token": env["CW_TOKEN"],
            "Content-Type": "application/json",
        }

    def _peticion(self, metodo, ruta, cuerpo=None):
        datos = json.dumps(cuerpo).encode() if cuerpo is not None else None
        pet = urllib.request.Request(
            self.base + ruta, data=datos, headers=self.cabeceras, method=metodo
        )
        try:
            with urllib.request.urlopen(pet, timeout=30) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            return {"_error": f"HTTP {e.code}: {e.read().decode()[:200]}"}
        except Exception as e:  # red caida, DNS, etc.
            return {"_error": str(e)}

    def contactos(self):
        """Todos los contactos, paginando hasta que una pagina venga vacia."""
        todos, pagina = [], 1
        while True:
            r = self._peticion("GET", f"/contacts?page={pagina}")
            if "_error" in r:
                salir(f"no puedo leer los contactos de Chatwoot: {r['_error']}")
            lote = r.get("payload", [])
            if not lote:
                return todos
            todos.extend(lote)
            pagina += 1
            if pagina > 200:  # tope de seguridad: 200 paginas es muchisimo
                di("!! aviso: corto en la pagina 200, hay mas contactos sin revisar")
                return todos

    def actualizar(self, id_contacto, cambios):
        return self._peticion("PUT", f"/contacts/{id_contacto}", cambios)

    def contacto(self, id_contacto):
        return self._peticion("GET", f"/contacts/{id_contacto}").get("payload", {})


def objetivo(contacto, tel_a_lid, lid_a_tel):
    """Que identifier y que telefono DEBERIA tener este contacto.

    Devuelve (identifier, telefono) o None si no sabemos su direccion nueva.
    """
    identificador = contacto.get("identifier") or ""
    if identificador.endswith("@g.us"):
        return None  # los grupos ya van por su propia direccion

    digitos = (contacto.get("phone_number") or "").lstrip("+")
    if not digitos:
        return None

    if digitos in tel_a_lid:
        return tel_a_lid[digitos], f"+{digitos}"

    # Caso torcido que crea Evolution: mete los digitos de la direccion nueva en
    # el campo del telefono. Se reconoce porque esos digitos SON un lid conocido.
    if digitos in lid_a_tel:
        return f"{digitos}@lid", f"+{lid_a_tel[digitos]}"

    return None


def main():
    simular = "--simular" in sys.argv

    env = entorno()
    for clave in ("POSTGRES_USER", "POSTGRES_PASSWORD", "CW_ACCOUNT_ID", "CW_TOKEN"):
        if not env.get(clave):
            salir(f"falta {clave} en el .env")

    tel_a_lid = pares_conocidos(env)
    lid_a_tel = {lid.split("@")[0]: tel for tel, lid in tel_a_lid.items()}
    di(f"equivalencias que conoce el motor: {len(tel_a_lid)}")
    if not tel_a_lid:
        # Sin un solo par no se puede distinguir "todo correcto" de "no he leido
        # nada". Es un fallo, no un exito silencioso.
        salir("no he encontrado ni una equivalencia telefono/direccion nueva; "
              "reviso antes de dar esto por bueno")

    cw = Chatwoot(env)
    contactos = cw.contactos()
    di(f"contactos en Chatwoot: {len(contactos)}\n")

    cambiados, correctos, sin_datos, fallos = [], 0, [], []

    for c in contactos:
        meta = objetivo(c, tel_a_lid, lid_a_tel)
        if meta is None:
            sin_datos.append(c)
            continue
        id_deseado, tel_deseado = meta

        cambios = {}
        if (c.get("identifier") or "") != id_deseado:
            cambios["identifier"] = id_deseado
        if (c.get("phone_number") or "") != tel_deseado:
            cambios["phone_number"] = tel_deseado
        # El nombre puesto por Evolution a veces son los digitos del lid.
        if (c.get("name") or "").strip() == id_deseado.split("@")[0]:
            cambios["name"] = tel_deseado

        if not cambios:
            correctos += 1
            continue

        etiqueta = f"[{c['id']}] {c.get('name')}"
        di(f"{etiqueta}")
        di(f"    ahora:  identifier={c.get('identifier')!r} telefono={c.get('phone_number')!r}")
        di(f"    queda:  identifier={id_deseado!r} telefono={tel_deseado!r}")

        if simular:
            cambiados.append(c["id"])
            continue

        r = cw.actualizar(c["id"], cambios)
        if "_error" in r:
            di(f"    !! no se pudo: {r['_error']}")
            fallos.append((c["id"], r["_error"]))
        else:
            cambiados.append(c["id"])

    # Verificar leyendo de vuelta: que lo escrito es lo que hay.
    no_cuadran = []
    if not simular:
        for id_contacto in cambiados:
            c = cw.contacto(id_contacto)
            meta = objetivo(c, tel_a_lid, lid_a_tel)
            if meta and (c.get("identifier") or "") != meta[0]:
                no_cuadran.append((id_contacto, c.get("identifier"), meta[0]))

    di("\n--- resumen ---")
    di(f"ya estaban bien:        {correctos}")
    di(f"{'se cambiarian' if simular else 'cambiados'}:{' ' * (14 if simular else 18)}{len(cambiados)}")
    di(f"sin equivalencia:       {len(sin_datos)}")
    for c in sin_datos:
        di(f"    - [{c['id']}] {c.get('name')} {c.get('phone_number')}"
              f"  (no ha escrito nunca, no sabemos su direccion nueva)")
    if fallos:
        di(f"FALLOS: {len(fallos)}")
        for id_contacto, motivo in fallos:
            di(f"    - [{id_contacto}] {motivo}")
    if no_cuadran:
        di("NO CUADRAN tras releer (esto es un fallo, no un aviso):")
        for id_contacto, tiene, deberia in no_cuadran:
            di(f"    - [{id_contacto}] tiene {tiene!r}, deberia {deberia!r}")

    hubo_algo = bool(cambiados or fallos or no_cuadran)
    if hubo_algo or "--cron" not in sys.argv:
        if "--cron" in sys.argv:
            print(f"===== {datetime.now():%Y-%m-%d %H:%M:%S} =====")
        for linea in SALIDA:
            print(linea)

    return 1 if (fallos or no_cuadran) else 0


if __name__ == "__main__":
    sys.exit(main())
