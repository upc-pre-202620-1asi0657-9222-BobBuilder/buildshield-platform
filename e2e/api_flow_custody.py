"""E2E de la etapa B2 por el gateway (http://localhost:8080)."""
import json
import random
import time
import urllib.error
import urllib.request
import uuid

BASE = "http://localhost:8080"


def call(method, path, body=None, token=None, key=False, raw=False):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if key:
        req.add_header("Idempotency-Key", str(uuid.uuid4()))
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            content = resp.read()
            return resp.status, (content if raw else (json.loads(content) if content else None))
    except urllib.error.HTTPError as err:
        content = err.read()
        try:
            return err.code, json.loads(content)
        except Exception:
            return err.code, content[:200]


def ok(label, status, body, expected=(200, 201, 202, 204)):
    print(f"[{'OK' if status in expected else 'FAIL'}] {label}: {status}")
    if status not in expected:
        print("    ", json.dumps(body, ensure_ascii=False)[:600] if not isinstance(body, bytes) else body)
    return body


def wait_for(label, fn, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        result = fn()
        if result:
            print(f"[OK] {label}")
            return result
        time.sleep(1)
    print(f"[FAIL] {label} (timeout)")
    return None


run = random.randint(100000, 999999)
ruc = "20" + str(random.randint(100000000, 999999999))
admin_email = f"ana.{run}@andina.pe"
pw = "Clave.Segura123"
s, b = call("POST", "/api/v1/auth/sign-up", {"ruc": ruc, "legalName": f"Constructora B2 {run} SAC",
                                              "adminFullName": "Ana Torres", "adminEmail": admin_email,
                                              "password": pw})
ok("sign-up", s, b)
s, b = call("POST", "/api/v1/auth/sign-in", {"email": admin_email, "password": pw})
admin = ok("sign-in admin", s, b)["accessToken"]

sub = wait_for("subscription current muestra la prueba", lambda: (lambda r: r[1] if r[0] == 200 else None)(
    call("GET", "/api/v1/subscriptions/current", token=admin)))
print("    ", sub)
s, b = call("GET", "/api/v1/plans", token=admin)
ok("plans", s, b)
print("    ", [(p["code"], p["monthlyPrice"], p["annualPrice"]) for p in b])

users = {}
for name, role in [("Luis Ramos", "SITE_MANAGER"), ("Rosa Quispe", "WAREHOUSE_MANAGER")]:
    email = name.split()[0].lower() + f".{run}@andina.pe"
    s, b = call("POST", "/api/v1/users", {"fullName": name, "email": email, "role": role, "password": pw},
                token=admin, key=True)
    users[role] = ok(f"crear usuario {role}", s, b)["id"]
    s, b = call("POST", "/api/v1/auth/sign-in", {"email": email, "password": pw})
    users[role + "_token"] = ok(f"sign-in {role}", s, b)["accessToken"]
site, wh = users["SITE_MANAGER_token"], users["WAREHOUSE_MANAGER_token"]

wait_for("notification tiene la copia de destinatarios (bandeja responde)", lambda: call(
    "GET", "/api/v1/notifications/unread-count", token=site)[0] == 200)

s, b = call("POST", "/api/v1/worksites", {"name": "Torre Norte", "address": "Av. Javier Prado 123",
                                          "district": "San Isidro", "city": "Lima", "startDate": "2026-10-01",
                                          "endDate": "2027-06-30"}, token=admin, key=True)
worksite = ok("obra", s, b)["id"]
s, b = call("POST", "/api/v1/warehouses", {"name": "Almacén Central", "type": "WAREHOUSE",
                                           "address": "Av. Argentina 2500"}, token=admin, key=True)
warehouse = ok("almacén", s, b)["id"]
s, b = call("POST", "/api/v1/materials", {"sku": f"CEM-{run}", "name": "Cemento Portland", "unit": "BAG",
                                          "wasteTolerancePercent": 2.5}, token=admin, key=True)
material = ok("material", s, b)["id"]
for uid, st, sid in [(users["SITE_MANAGER"], "WORKSITE", worksite), (users["WAREHOUSE_MANAGER"], "WAREHOUSE",
                                                                      warehouse)]:
    s, b = call("POST", "/api/v1/assignments", {"userId": uid, "siteType": st, "siteId": sid}, token=admin, key=True)
    ok(f"asignación {st}", s, b)

s, b = call("GET", "/api/v1/audit/events?size=100", token=admin)
ok("audit/events", s, b)
types = sorted({i["eventType"] for i in b["items"]}) if s == 200 else []
print("     tipos registrados:", types, "total", b.get("total") if isinstance(b, dict) else None)
s, b = call("GET", "/api/v1/audit/events", token=site)
ok("audit/events como encargado de obra → 403", s, b, expected=(403,))

# ---- Flujo con ordering e inventory ----
time.sleep(2)
s, b = call("POST", "/api/v1/stock/entries", {"warehouseId": warehouse, "materialId": material, "quantity": 100,
                                               "note": "Guía E2E"}, token=wh, key=True)
ok("stock entry", s, b)
order = None
def place():
    st, bd = call("POST", "/api/v1/orders", {"worksiteId": worksite, "warehouseId": warehouse,
                                             "lines": [{"materialId": material, "quantity": 40}]}, token=site, key=True)
    return bd if st == 201 else None
order = wait_for("pedido registrado", place)
if order:
    s, b = call("POST", f"/api/v1/orders/{order['id']}/approve", token=wh, key=True)
    ok("aprobar pedido", s, b)
    approved = wait_for("pedido aprobado (saga de reserva)", lambda: (lambda r: r[1] if r[1].get("status") == "IN_REVIEW"
                                                                    else None)(call("GET", f"/api/v1/orders/{order['id']}", token=wh)))
    line = order["lines"][0]["id"]
    s, b = call("POST", "/api/v1/dispatches", {"orderId": order["id"], "lines": [{"orderLineId": line,
                                                                                 "quantity": 40}]}, token=wh, key=True)
    dispatch = ok("despacho", s, b)
    did = dispatch["id"]
    ok("transportista", *call("PATCH", f"/api/v1/dispatches/{did}/carrier", {"carrierName": "Transportes Rímac SAC",
                                                                            "carrierDocument": "20555666777",
                                                                            "plate": "ABC-123"}, token=wh))
    ok("pesaje de salida", *call("POST", f"/api/v1/dispatches/{did}/departure-weighing", {"grossKg": 3000,
                                                                                           "tareKg": 1000}, token=wh,
                               key=True))
    ok("salida", *call("POST", f"/api/v1/dispatches/{did}/depart", token=wh, key=True))
    ok("incidencia", *call("POST", f"/api/v1/dispatches/{did}/incidents", {"type": "DELAY",
                                                                          "observation": "Tráfico en la Panamericana"},
                           token=wh, key=True))
    wait_for("notificación de despacho en tránsito al encargado de obra", lambda: call(
        "GET", "/api/v1/notifications/unread-count", token=site)[1].get("unreadCount", 0) >= 2)
    s, b = call("GET", "/api/v1/notifications", token=site)
    print("     bandeja obra:", [(i["type"], i["link"]) for i in b["items"]])
    s, b = call("POST", "/api/v1/receptions", {"dispatchId": did}, token=site, key=True)
    reception = ok("abrir recepción", s, b)
    rid = reception["id"]
    for l in reception["lines"]:
        ok("línea recibida 37 de 40", *call("PUT", f"/api/v1/receptions/{rid}/lines/{l['id']}", {"receivedQty": 37},
                                           token=site))
    ok("confirmar recepción", *call("POST", f"/api/v1/receptions/{rid}/confirm", token=site, key=True))
    discs = wait_for("discrepancia abierta automáticamente", lambda: (lambda r: r[1] if r[0] == 200 and r[1] else None)(
        call("GET", f"/api/v1/discrepancies?dispatchId={did}", token=site)))
    if discs:
        d = discs[0]
        print("     discrepancia:", d["typeLabel"], d["quantity"], d["statusLabel"], d["manifestCode"])
        wait_for("notificación de recepción con discrepancias al almacén", lambda: any(
            i["type"] == "RECEPTION_WITH_DISCREPANCIES" for i in call("GET", "/api/v1/notifications",
                                                                       token=wh)[1]["items"]))
        jpeg = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0, 16]) + b"JFIF" + bytes(100)
        boundary = "----b2" + str(run)
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"foto.jpg\"\r\n"
                f"Content-Type: image/jpeg\r\n\r\n").encode() + jpeg + f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(BASE + f"/api/v1/discrepancies/{d['id']}/evidences", data=body, method="POST")
        req.add_header("Content-Type", "multipart/form-data; boundary=" + boundary)
        req.add_header("Authorization", "Bearer " + site)
        with urllib.request.urlopen(req, timeout=30) as resp:
            evidence = json.loads(resp.read())
            print(f"[OK] evidencia subida: {resp.status} url={evidence['url'][:90]}...")
        s, b = call("GET", evidence["url"], raw=True)
        ok("foto por la url firmada sin Authorization (vía gateway)", s, b if s != 200 else "imagen", expected=(200,))
        with urllib.request.urlopen("http://localhost:8085" + evidence["url"], timeout=30) as resp:
            print(f"[OK] foto directa en discrepancy-service (8085) sin Authorization: {resp.status} "
                  f"{resp.headers.get('Content-Type')} {len(resp.read())} bytes")
        ok("responder", *call("POST", f"/api/v1/discrepancies/{d['id']}/response", {"text": "Se repone mañana"},
                              token=wh, key=True))
        wait_for("aviso de respuesta al encargado de obra", lambda: any(
            i["type"] == "DISCREPANCY_RESPONDED" for i in call("GET", "/api/v1/notifications", token=site)[1]["items"]))
    custody = wait_for("custodia con los pasos", lambda: (lambda r: r[1] if r[0] == 200 and len(r[1]["events"]) >= 6
                                                          else None)(call("GET", f"/api/v1/dispatches/{did}/custody",
                                                                          token=site)))
    if custody:
        print("     custodia", custody["manifestCode"], [(e["type"], e["actorName"], e["detail"]) for e in
                                                      custody["events"]])
