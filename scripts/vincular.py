#!/usr/bin/env python3
# =============================================================================
#  Pagina de vinculacion: ensena el QR de un numero SIEMPRE FRESCO.
#
#  El problema que resuelve: el QR de WhatsApp caduca en menos de un minuto.
#  Mandar un PNG por chat no funciona casi nunca — para cuando el cliente abre
#  la imagen ya esta muerto, y lo que ve es "codigo QR caducado" en el movil.
#  Aqui la pagina se repinta sola cada pocos segundos y ademas detecta el
#  momento exacto en que el numero queda conectado.
#
#  La apikey NO sale al navegador: la peticion a Evolution se hace desde aqui.
#  El acceso va por un token largo en la URL (VINCULAR_TOKEN), porque quien
#  abra esta pagina puede enganchar SU WhatsApp a la bandeja del cliente.
#
#  Rutas (TOK = VINCULAR_TOKEN, NUM = n1 | n2):
#    /vincular/TOK/NUM            -> pagina
#    /vincular/TOK/NUM/qr.png     -> QR actual en PNG
#    /vincular/TOK/NUM/estado     -> {"estado": "...", "hay_qr": true}
# =============================================================================
import base64
import json
import os
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ["VINCULAR_TOKEN"]
PUERTO = int(os.environ.get("VINCULAR_PORT", "8099"))

# n1 -> (url interna del contenedor, apikey, nombre de la instancia)
NUMEROS = {}
for n in ("n1", "n2"):
    up = n.upper()
    if os.environ.get(f"{up}_API_KEY") and os.environ.get(f"{up}_INSTANCE"):
        NUMEROS[n] = (
            f"http://evolution-{n}:8080",
            os.environ[f"{up}_API_KEY"],
            os.environ[f"{up}_INSTANCE"],
        )


def evolution(num, ruta):
    base, key, inst = NUMEROS[num]
    req = urllib.request.Request(
        f"{base}{ruta.replace('{i}', inst)}",
        headers={"apikey": key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode())


def estado_de(num):
    try:
        return evolution(num, "/instance/connectionState/{i}")["instance"]["state"]
    except Exception:
        return "desconocido"


def qr_de(num):
    """PNG del QR actual, o None si ya no hay QR que ensenar."""
    # ⚠️ /instance/connect NO es una consulta inocente: no "mira si hay QR",
    # le PIDE al motor que abra conexion. Si el numero ya esta vinculado y
    # con su socket abierto, esta llamada puede dejar DOS sockets sobre la
    # misma sesion; WhatsApp expulsa a uno con "conflict: replaced", el que
    # queda reintenta, y se entra en un bucle que tumba el numero.
    # La pagina refresca el QR cada 12 segundos, o sea que dejarla abierta
    # sobre un numero ya conectado seria pegarle 5 veces por minuto.
    # Por eso: si esta conectado, no se llama y ya esta.
    if estado_de(num) == "open":
        return None
    try:
        d = evolution(num, "/instance/connect/{i}")
    except urllib.error.HTTPError:
        return None
    except Exception:
        return None
    b64 = (d.get("base64") or "").split(",")[-1]
    return base64.b64decode(b64) if b64 else None


PAGINA = """<!doctype html><html lang="es"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vincular WhatsApp &mdash; %(titulo)s</title>
<style>
 :root{color-scheme:light dark}
 body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;margin:0;
      min-height:100vh;display:flex;align-items:center;justify-content:center;
      background:#0f1720;color:#e7edf3;padding:24px}
 .caja{max-width:460px;width:100%%;text-align:center}
 h1{font-size:20px;margin:0 0 4px}
 .sub{color:#93a4b5;font-size:14px;margin:0 0 20px}
 .marco{background:#fff;border-radius:16px;padding:16px;display:inline-block;
        min-height:300px;min-width:300px}
 img{width:280px;height:280px;display:block;image-rendering:pixelated}
 ol{text-align:left;color:#c3d0dc;font-size:14px;line-height:1.7;
    margin:22px auto 0;max-width:360px;padding-left:20px}
 .estado{margin-top:18px;font-size:14px;color:#93a4b5}
 .ok{background:#0e3b23;border:1px solid #1f7a45;color:#8ff0b6;
     padding:18px;border-radius:12px;font-size:16px}
 .aviso{color:#f0c674;font-size:13px;margin-top:14px}
</style></head><body><div class="caja">
 <h1>Vincular WhatsApp</h1>
 <p class="sub">Bandeja del CRM: %(titulo)s</p>
 <div id="zona">
   <div class="marco"><img id="qr" alt="Codigo QR"></div>
   <ol>
     <li>Abre WhatsApp en el m&oacute;vil que quieres vincular.</li>
     <li>Men&uacute; (o Ajustes) &rarr; <b>Dispositivos vinculados</b>.</li>
     <li>Pulsa <b>Vincular un dispositivo</b>.</li>
     <li>Apunta la c&aacute;mara a este c&oacute;digo.</li>
   </ol>
   <p class="aviso">El c&oacute;digo se renueva solo cada pocos segundos.
      No hace falta recargar la p&aacute;gina.</p>
 </div>
 <p class="estado" id="estado">Cargando&hellip;</p>
</div>
<script>
 var base = location.pathname.replace(/\\/$/, '');
 var hayQR = false;   // ¿hay de verdad un codigo pintado en pantalla?
 // Cuando no hay QR el servidor responde 204 (sin contenido) y el navegador
 // pinta el icono de imagen rota. Eso es lo que hacia parecer que la pagina
 // estaba estropeada cuando en realidad el numero ya estaba vinculado.
 // Aqui se sustituye el hueco por una explicacion en texto.
 // Se esconde la ZONA entera, no solo el marco: dentro estan tambien los
 // pasos ("apunta la camara a este codigo") y dejarlos a la vista cuando no
 // hay ningun codigo es peor que la imagen rota, porque manda al usuario a
 // hacer algo que no puede hacer.
 function ocultarQR(mensaje){
   var zona = document.getElementById('zona');
   if (zona) zona.style.display = 'none';
   document.getElementById('estado').textContent = mensaje;
 }
 function mostrarQR(){
   var zona = document.getElementById('zona');
   if (zona) zona.style.display = '';
 }
 function pintarQR(){
   var img = document.getElementById('qr');
   // Si mas tarde SI aparece un QR (por ejemplo tras cerrar sesion en el
   // movil), hay que volver a ensenar el marco que se oculto antes.
   img.onload = function(){
     hayQR = true;
     mostrarQR();
     document.getElementById('estado').textContent =
       'Esperando a que escanees el c\\u00f3digo\\u2026';
   };
   img.onerror = function(){
     hayQR = false;
     ocultarQR('Ahora mismo no hay c\\u00f3digo que escanear. ' +
               'Lo normal es que este n\\u00famero ya est\\u00e9 vinculado.');
   };
   img.src = base + '/qr.png?t=' + Date.now();
 }
 function mirarEstado(){
   fetch(base + '/estado').then(function(r){ return r.json(); }).then(function(d){
     if (d.estado === 'open'){
       // Sin esto, si la zona se habia ocultado antes por no haber QR, el
       // aviso de "conectado correctamente" se escribiria DENTRO de un
       // contenedor invisible y el usuario no veria nada.
       mostrarQR();
       document.getElementById('zona').innerHTML =
         '<div class="ok">&#10003; N&uacute;mero conectado correctamente.<br>' +
         'Ya puedes cerrar esta p&aacute;gina.</div>';
       document.getElementById('estado').textContent = '';
       clearInterval(tQR); clearInterval(tEst);
     } else if (hayQR){
       // 🚨 ESTE CASO VA ANTES QUE EL DE 'connecting', Y EL ORDEN IMPORTA.
       // Mientras hay un QR en pantalla el estado ES 'connecting': es
       // exactamente el estado de un numero esperando a que lo escaneen.
       // Con la comprobacion de 'connecting' delante, la pagina ESCONDIA el
       // codigo cada 4 segundos y encima ponia "no hace falta escanear nada",
       // o sea lo contrario de lo que habia que hacer. El codigo aparecia y
       // desaparecia y era imposible escanearlo. (31-Ago-2026)
       // Si hay codigo pintado, mandan las instrucciones de escanearlo.
       // textContent, asi que aqui van caracteres de verdad y NO entidades HTML
       document.getElementById('estado').textContent =
         'Esperando a que escanees el c\\u00f3digo\\u2026';
     } else if (d.estado === 'connecting'){
       // SIN codigo en pantalla y negociando: aqui si esta reconectandose
       // solo y no hay nada que escanear. Antes se quedaba el hueco de la
       // imagen rota y ponia "esperando a que escanees".
       ocultarQR('Este n\\u00famero est\\u00e1 reconect\\u00e1ndose solo. ' +
                 'No hace falta escanear nada: espera un momento.');
     } else {
       // Sin QR en pantalla no se puede pedir que lo escanee: seria mandarle
       // a buscar algo que no esta.
       ocultarQR('Preparando el c\\u00f3digo\\u2026 Si no aparece en unos ' +
                 'segundos, lo normal es que este n\\u00famero ya est\\u00e9 vinculado.');
     }
   }).catch(function(){});
 }
 pintarQR(); mirarEstado();
 var tQR  = setInterval(pintarQR, 12000);
 var tEst = setInterval(mirarEstado, 4000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):  # una linea por peticion, sin ruido
        print("%s %s" % (self.address_string(), fmt % a), flush=True)

    def responder(self, code, cuerpo, tipo):
        if isinstance(cuerpo, str):
            cuerpo = cuerpo.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(cuerpo)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_GET(self):
        partes = self.path.split("?")[0].strip("/").split("/")
        # ["vincular", TOKEN, NUM, (qr.png|estado)?]
        if len(partes) < 3 or partes[0] != "vincular":
            return self.responder(404, "no", "text/plain")
        # comparacion en tiempo constante, por higiene
        import hmac
        if not hmac.compare_digest(partes[1], TOKEN):
            return self.responder(404, "no", "text/plain")
        num = partes[2]
        if num not in NUMEROS:
            return self.responder(404, "numero desconocido", "text/plain")
        cola = partes[3] if len(partes) > 3 else ""

        if cola == "estado":
            e = estado_de(num)
            return self.responder(
                200, json.dumps({"estado": e}), "application/json")

        if cola == "qr.png":
            png = qr_de(num)
            if png is None:
                return self.responder(204, b"", "image/png")
            return self.responder(200, png, "image/png")

        if cola == "":
            return self.responder(
                200, PAGINA % {"titulo": NUMEROS[num][2]}, "text/html; charset=utf-8")

        return self.responder(404, "no", "text/plain")


if __name__ == "__main__":
    print("vincular: escuchando en :%d para %s" % (PUERTO, ", ".join(NUMEROS)), flush=True)
    ThreadingHTTPServer(("0.0.0.0", PUERTO), Handler).serve_forever()
