"""Flujo real de la etapa B1 a través del gateway (http://localhost:8080): saga de reserva, despacho y recepción."""
import json
import random
import sys
import time
import urllib.error
import urllib.request
import uuid

BASE = "http://localhost:8080"
LOG = []


def call(method, path, body=None, token=None, idem=False, expect=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if idem:
        req.add_header("Idempotency-Key", str(uuid.uuid4()))
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            status, text = resp.status, resp.read().decode()
    except urllib.error.HTTPError as err:
        status, text = err.code, err.read().decode()
    payload = json.loads(text) if text.strip().startswith(("{", "[")) else text
    LOG.append(f"{method} {path} -> {status}")
    print(f"{method} {path} -> {status}")
    if expect is not None and status != expect:
        print("  BODY:", text[:800])
        raise SystemExit(f"FALLO: {method} {path} esperaba {expect} y recibió {status}")
    return status, payload


def until(description, fn, timeout=30):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            print(f"  ok: {description}")
            return last
        time.sleep(0.7)
    raise SystemExit(f"FALLO: no se cumplió '{description}' en {timeout}s (último: {last})")


def retry(method, path, body, token, expect, idem=False, timeout=30):
    """Reintenta mientras la copia local (proyección) aún no llega: 404 por consistencia eventual."""
    def attempt():
        status, payload = call(method, path, body, token, idem)
        return (status, payload) if status == expect else None
    return until(f"{method} {path} responde {expect}", attempt, timeout)[1]


def main():
    run = random.randint(100000000, 999999999)
    pwd = "Segura123"
    admin_email = f"ana.{run}@andina.pe"
    call("POST", "/api/v1/auth/sign-up", {"ruc": f"20{run}", "legalName": f"Constructora Andina {run} SAC",
                                         "adminFullName": "Ana Torres", "adminEmail": admin_email, "password": pwd},
         expect=201)
    _, auth = call("POST", "/api/v1/auth/sign-in", {"email": admin_email, "password": pwd}, expect=200)
    admin = auth["accessToken"]
    _, site_user = call("POST", "/api/v1/users", {"fullName": "Jorge Huaman", "email": f"jorge.{run}@andina.pe",
                                                 "role": "SITE_MANAGER", "password": pwd}, admin, expect=201)
    _, wh_user = call("POST", "/api/v1/users", {"fullName": "Rosa Quispe", "email": f"rosa.{run}@andina.pe",
                                               "role": "WAREHOUSE_MANAGER", "password": pwd}, admin, expect=201)
    _, worksite = call("POST", "/api/v1/worksites", {"name": "Torre Norte", "address": "Av. Javier Prado 123",
                                                    "district": "San Isidro", "city": "Lima",
                                                    "startDate": "2026-11-01", "endDate": "2027-06-30"}, admin,
                       expect=201)
    _, warehouse = call("POST", "/api/v1/warehouses", {"name": "Almacén Central", "type": "WAREHOUSE",
                                                      "address": "Av. Argentina 2500, Callao"}, admin, expect=201)
    _, material = call("POST", "/api/v1/materials", {"sku": f"CEM-{run % 1000:03d}", "name": "Cemento Portland tipo I",
                                                    "unit": "BAG", "wasteTolerancePercent": 2.5}, admin, expect=201)
    call("POST", "/api/v1/assignments", {"userId": site_user["id"], "siteType": "WORKSITE", "siteId": worksite["id"]},
         admin, expect=201)
    call("POST", "/api/v1/assignments", {"userId": wh_user["id"], "siteType": "WAREHOUSE", "siteId": warehouse["id"]},
         admin, expect=201)
    _, s = call("POST", "/api/v1/auth/sign-in", {"email": f"jorge.{run}@andina.pe", "password": pwd}, expect=200)
    site = s["accessToken"]
    _, w = call("POST", "/api/v1/auth/sign-in", {"email": f"rosa.{run}@andina.pe", "password": pwd}, expect=200)
    wh = w["accessToken"]

    # Carga de existencias en inventory (espera las proyecciones de organization).
    retry("POST", "/api/v1/stock/entries", {"warehouseId": warehouse["id"], "materialId": material["id"],
                                            "quantity": 100, "note": "Guía 001"}, wh, 201, idem=True)

    # Pedido en ordering (espera sus proyecciones) y aprobación asíncrona (saga).
    order = retry("POST", "/api/v1/orders", {"worksiteId": worksite["id"], "warehouseId": warehouse["id"],
                                             "requiredDate": "2026-11-20", "notes": "Losa piso 3",
                                             "lines": [{"materialId": material["id"], "quantity": 40}]},
                  site, 201, idem=True)
    assert order["requiredDate"] == "2026-11-20", order
    _, approving = call("POST", f"/api/v1/orders/{order['id']}/approve", None, wh, idem=True, expect=200)
    print("  estado tras aprobar:", approving["status"], approving.get("statusLabel"))
    until("pedido IN_REVIEW tras StockReserved",
          lambda: call("GET", f"/api/v1/orders/{order['id']}", token=site)[1]["status"] == "IN_REVIEW")

    def stock_row():
        _, rows = call("GET", f"/api/v1/stock?warehouseId={warehouse['id']}", token=wh)
        return rows[0] if rows else None
    until("reservado 40 y disponible 60", lambda: (r := stock_row()) and float(r["reservedQty"]) == 40
          and float(r["availableQty"]) == 60)

    # Pedido sin stock: vuelve a REGISTERED con el motivo.
    short = call("POST", "/api/v1/orders", {"worksiteId": worksite["id"], "warehouseId": warehouse["id"],
                                            "requiredDate": "2026-11-21",
                                            "lines": [{"materialId": material["id"], "quantity": 500}]},
                 site, idem=True, expect=201)[1]
    call("POST", f"/api/v1/orders/{short['id']}/approve", None, wh, idem=True, expect=200)
    rejected = until("pedido sin stock vuelve a REGISTERED con motivo",
                     lambda: (o := call("GET", f"/api/v1/orders/{short['id']}", token=site)[1])["status"] == "REGISTERED"
                     and o.get("rejectionReason") and o)
    print("  motivo:", rejected["rejectionReason"])

    # Despacho: preparar, transportista, pesaje, salida.
    line_id = order["lines"][0]["id"]
    _, dispatch = call("POST", "/api/v1/dispatches", {"orderId": order["id"],
                                                     "lines": [{"orderLineId": line_id, "quantity": 40}]},
                       wh, idem=True, expect=201)
    call("PATCH", f"/api/v1/dispatches/{dispatch['id']}/carrier", {"carrierName": "Transportes Rímac SAC",
                                                                   "carrierDocument": "20555666777",
                                                                   "plate": "ABC-123"}, wh, expect=200)
    call("POST", f"/api/v1/dispatches/{dispatch['id']}/departure-weighing", {"grossKg": 2550.5, "tareKg": 550.5},
         wh, expect=200)
    _, departed = call("POST", f"/api/v1/dispatches/{dispatch['id']}/depart", None, wh, idem=True, expect=200)
    assert departed["status"] == "IN_TRANSIT", departed
    call("GET", f"/api/v1/dispatches/{dispatch['id']}/manifest", token=site, expect=200)
    _, by_code = call("GET", f"/api/v1/dispatches/by-manifest/{dispatch['manifestCode']}", token=site, expect=200)
    assert by_code["id"] == dispatch["id"]
    call("POST", f"/api/v1/dispatches/{dispatch['id']}/incidents", {"type": "DELAY",
                                                                    "observation": "Tráfico en la Vía Expresa"},
         wh, expect=201)
    until("salida descontada: reservado 0, disponible 60",
          lambda: (r := stock_row()) and float(r["reservedQty"]) == 0 and float(r["availableQty"]) == 60)

    # Recepción en obra por código de manifiesto, pesaje de llegada, parcial y conformidad.
    _, reception = call("POST", "/api/v1/receptions", {"manifestCode": dispatch["manifestCode"]}, site, expect=201)
    rline = reception["lines"][0]["id"]
    _, weighing = call("POST", f"/api/v1/receptions/{reception['id']}/arrival-weighing",
                       {"grossKg": 2540.5, "tareKg": 550.5}, site, expect=201)
    print("  pesaje de llegada:", weighing)
    call("PUT", f"/api/v1/receptions/{reception['id']}/lines/{rline}", {"receivedQty": 20}, site, expect=200)
    call("POST", f"/api/v1/receptions/{reception['id']}/partial", None, site, idem=True, expect=200)

    def worksite_qty():
        _, rows = call("GET", f"/api/v1/stock/worksites?worksiteId={worksite['id']}", token=site)
        return float(rows[0]["availableQty"]) if rows else 0.0
    until("obra con 20 tras el parcial", lambda: worksite_qty() == 20)
    call("PUT", f"/api/v1/receptions/{reception['id']}/lines/{rline}", {"receivedQty": 39}, site, expect=200)
    _, confirmed = call("POST", f"/api/v1/receptions/{reception['id']}/confirm", None, site, idem=True, expect=200)
    assert confirmed["status"] == "CONFIRMED", confirmed
    until("obra con 39 tras la conformidad (solo suma el delta 19)", lambda: worksite_qty() == 39)
    _, final_dispatch = call("GET", f"/api/v1/dispatches/{dispatch['id']}", token=site, expect=200)
    assert final_dispatch["status"] == "RECEIVED", final_dispatch
    final_order = until("pedido cerrado tras la recepción completa",
                        lambda: (o := call("GET", f"/api/v1/orders/{order['id']}", token=site)[1])["status"] == "CLOSED" and o)
    print("  pedido final:", final_order["status"], final_order["lines"][0])
    _, movements = call("GET", f"/api/v1/stock/movements?locationId={warehouse['id']}", token=wh, expect=200)
    print("  movimientos del almacén:", [m["type"] for m in movements])
    print("\nRESULTADO: flujo completo OK,", len(LOG), "peticiones")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as exit_error:
        print(exit_error)
        sys.exit(1)
