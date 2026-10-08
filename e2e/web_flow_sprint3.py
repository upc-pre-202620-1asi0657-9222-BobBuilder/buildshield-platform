"""E2E de la web (4200) contra los 9 microservicios por el gateway (8080).
Prepara datos por la API y recorre las pantallas del Sprint 3 con login real por rol."""
import json, random, sys, time, uuid, urllib.request, urllib.error
from playwright.sync_api import sync_playwright

API = "http://localhost:8080"
WEB = "http://localhost:4200"
OUT = sys.argv[1]
PW = "Clave.Segura123"
fails, page_errors, api_errors = [], [], []


def call(method, path, body=None, token=None, key=False):
    req = urllib.request.Request(API + path, data=json.dumps(body).encode() if body is not None else None, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if key:
        req.add_header("Idempotency-Key", str(uuid.uuid4()))
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            c = r.read()
            return r.status, json.loads(c) if c else None
    except urllib.error.HTTPError as e:
        c = e.read()
        try:
            return e.code, json.loads(c)
        except Exception:
            return e.code, c[:200]


def must(label, res, ok=(200, 201)):
    s, b = res
    print(f"[{'OK' if s in ok else 'FAIL'}] api {label}: {s}")
    if s not in ok:
        fails.append(label)
        print("   ", b)
    return b


def wait(label, fn, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        r = fn()
        if r:
            print(f"[OK] {label}")
            return r
        time.sleep(1)
    print(f"[FAIL] {label}")
    fails.append(label)


# ---------- datos por la API ----------
run = random.randint(100000, 999999)
admin_email = f"ana.{run}@andina.pe"
must("sign-up", call("POST", "/api/v1/auth/sign-up", {"ruc": "20" + str(random.randint(100000000, 999999999)),
     "legalName": f"Constructora Andina {run} SAC", "adminFullName": "Ana Torres", "adminEmail": admin_email,
     "password": PW}))
admin = must("sign-in admin", call("POST", "/api/v1/auth/sign-in", {"email": admin_email, "password": PW}))["accessToken"]
emails, ids, tokens = {}, {}, {}
for name, role in [("Luis Ramos", "SITE_MANAGER"), ("Rosa Quispe", "WAREHOUSE_MANAGER")]:
    emails[role] = name.split()[0].lower() + f".{run}@andina.pe"
    ids[role] = must(f"usuario {role}", call("POST", "/api/v1/users", {"fullName": name, "email": emails[role],
                     "role": role, "password": PW}, token=admin, key=True))["id"]
    tokens[role] = must(f"sign-in {role}", call("POST", "/api/v1/auth/sign-in",
                        {"email": emails[role], "password": PW}))["accessToken"]
site_t, wh_t = tokens["SITE_MANAGER"], tokens["WAREHOUSE_MANAGER"]
time.sleep(1)
worksite = must("obra", call("POST", "/api/v1/worksites", {"name": "Torre Norte", "address": "Av. Javier Prado 123",
                "district": "San Isidro", "city": "Lima", "startDate": "2026-10-01", "endDate": "2027-06-30"},
                token=admin, key=True))["id"]
warehouse = must("almacén", call("POST", "/api/v1/warehouses", {"name": "Almacén Central", "type": "WAREHOUSE",
                 "address": "Av. Argentina 2500"}, token=admin, key=True))["id"]
material = must("material", call("POST", "/api/v1/materials", {"sku": f"CEM-{run}", "name": "Cemento Portland",
                "unit": "BAG", "wasteTolerancePercent": 2.5}, token=admin, key=True))["id"]
material2 = must("material 2", call("POST", "/api/v1/materials", {"sku": f"FIE-{run}", "name": "Fierro corrugado 1/2",
                 "unit": "UNIT", "wasteTolerancePercent": 1.0}, token=admin, key=True))["id"]
for uid, st, sid in [(ids["SITE_MANAGER"], "WORKSITE", worksite), (ids["WAREHOUSE_MANAGER"], "WAREHOUSE", warehouse)]:
    must(f"asignación {st}", call("POST", "/api/v1/assignments", {"userId": uid, "siteType": st, "siteId": sid},
         token=admin, key=True))
time.sleep(2)
for m, q in [(material, 100), (material2, 300)]:
    must("ingreso de stock", call("POST", "/api/v1/stock/entries", {"warehouseId": warehouse, "materialId": m,
         "quantity": q, "note": "Guía de remisión 001"}, token=wh_t, key=True))


def place(lines):
    s, b = call("POST", "/api/v1/orders", {"worksiteId": worksite, "warehouseId": warehouse,
                "requiredDate": "2026-10-20", "lines": lines}, token=site_t, key=True)
    return b if s == 201 else None


order = wait("pedido registrado", lambda: place([{"materialId": material, "quantity": 40},
                                                 {"materialId": material2, "quantity": 120}]))
short = place([{"materialId": material, "quantity": 500}])


# ---------- web ----------
def sign_in(browser, role_email, w=1280, h=900):
    ctx = browser.new_context(viewport={"width": w, "height": h})
    pg = ctx.new_page()
    pg.on("pageerror", lambda e: page_errors.append(str(e)))
    def on_resp(r):
        if "/api/" in r.url and r.status >= 400 and r.status != 409:
            try:
                body = r.text()[:300]
            except Exception:
                body = ""
            api_errors.append(f"{r.status} {r.request.method} {r.url} req={r.request.post_data} resp={body}")
    pg.on("response", on_resp)
    pg.goto(WEB + "/sign-in")
    pg.fill("#email", role_email)
    pg.fill("#password", PW)
    pg.click("button[type=submit]")
    pg.wait_for_url(lambda u: "/sign-in" not in u, timeout=15000)
    pg.wait_for_timeout(1200)
    return pg


def shot(pg, name):
    pg.wait_for_timeout(900)
    pg.screenshot(path=f"{OUT}/{name}.png", full_page=True)
    print(f"[OK] captura {name}")


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="C:/Program Files/Google/Chrome/Application/chrome.exe")

    # Almacén aprueba por la web: «Aprobando» -> «Aprobado» (saga de reserva)
    wh = sign_in(b, emails["WAREHOUSE_MANAGER"])
    wh.goto(f"{WEB}/orders/{order['id']}")
    wh.wait_for_selector("text=Aprobar pedido")
    shot(wh, "01-pedido-registrado")
    wh.click("text=Aprobar pedido")
    wh.wait_for_selector("text=Pedido aprobado y stock reservado", timeout=20000)
    shot(wh, "02-pedido-aprobado-saga")
    wh.goto(f"{WEB}/orders/{short['id']}")
    wh.click("text=Aprobar pedido")
    wh.wait_for_selector("text=No se pudo aprobar", timeout=20000)
    shot(wh, "03-pedido-rechazado-sin-stock")

    # Despacho por la API (pantallas del Sprint 2 ya documentadas)
    lines = [{"orderLineId": l["id"], "quantity": l["requested"]} for l in order["lines"]]
    d = must("despacho", call("POST", "/api/v1/dispatches", {"orderId": order["id"], "lines": lines}, token=wh_t, key=True))
    did = d["id"]
    must("transportista", call("PATCH", f"/api/v1/dispatches/{did}/carrier", {"carrierName": "Transportes Rímac SAC",
         "carrierDocument": "20555666777", "plate": "ABC-123"}, token=wh_t))
    must("pesaje salida", call("POST", f"/api/v1/dispatches/{did}/departure-weighing", {"grossKg": 3000, "tareKg": 1000},
         token=wh_t, key=True))
    must("salida", call("POST", f"/api/v1/dispatches/{did}/depart", token=wh_t, key=True))
    must("incidencia", call("POST", f"/api/v1/dispatches/{did}/incidents", {"type": "DELAY",
         "observation": "Tráfico en la Panamericana Sur"}, token=wh_t, key=True))
    wh.goto(f"{WEB}/tracking")
    shot(wh, "04-en-ruta")
    wh.goto(f"{WEB}/dispatches/{did}")
    shot(wh, "05-despacho-incidencia")

    # Obra (celular): recepción con pesaje, parcial y conformidad con faltante
    site = sign_in(b, emails["SITE_MANAGER"], 390, 844)
    site.goto(f"{WEB}/notifications")
    shot(site, "06-notificaciones-obra")
    site.goto(f"{WEB}/reception")
    shot(site, "07-recepcion-lista")
    site.click("a.dispatch-card")
    site.wait_for_selector("app-reception-comparison input")
    site.fill("#arrivalGross", "2540")
    site.fill("#arrivalTare", "550")
    site.click("text=Registrar pesaje de llegada")
    site.wait_for_timeout(1500)
    def line(name):
        return site.locator("app-reception-comparison li", has_text=name).locator("input")
    cement, steel = line("Cemento Portland"), line("Fierro corrugado")
    cement.fill("20")
    cement.blur()
    steel.fill("0")
    steel.blur()
    site.wait_for_timeout(1500)
    site.click("button.partial")
    site.wait_for_timeout(1500)
    shot(site, "08-recepcion-parcial")
    cement.fill("37")
    cement.blur()
    steel.fill("120")
    steel.blur()
    site.wait_for_timeout(2500)
    site.click("button.confirm")
    site.wait_for_selector(".discrepancy-notice a", timeout=20000)
    shot(site, "09-recepcion-confirmada-discrepancia")
    site.click(".discrepancy-notice a")
    site.wait_for_selector("input[type=file]", state="attached")
    photo = site.screenshot()
    site.set_input_files("input[type=file]", files=[{"name": "bolsas-rotas.png", "mimeType": "image/png", "buffer": photo}])
    site.wait_for_selector(".evidence img, img[src*='/evidences/']", timeout=20000)
    shot(site, "10-discrepancia-evidencia")

    # Almacén responde; obra acepta
    wh.goto(f"{WEB}/discrepancies")
    shot(wh, "11-discrepancias-almacen")
    wh.locator("tbody tr a").first.click()
    wh.fill("#responseText", "Se repone en el siguiente despacho")
    wh.click("button.respond")
    wh.wait_for_timeout(1500)
    shot(wh, "12-discrepancia-respondida")
    site.reload()
    site.wait_for_selector("button.accept", timeout=20000)
    site.click("button.accept")
    site.wait_for_timeout(1500)
    shot(site, "13-discrepancia-aceptada")
    wh.goto(f"{WEB}/dispatches/{did}/custody")
    wh.wait_for_timeout(1500)
    shot(wh, "14-custodia")
    wh.goto(f"{WEB}/notifications")
    shot(wh, "15-notificaciones-almacen")
    b.close()

ws = must("stock obra", call("GET", f"/api/v1/stock/worksites?worksiteId={worksite}", token=admin))
print("stock obra:", [(i.get("sku"), i.get("available", i.get("quantity"))) for i in (ws if isinstance(ws, list) else ws.get("items", []))])
print("fallas:", fails)
print("errores de página:", page_errors)
print("errores de API:", api_errors)
