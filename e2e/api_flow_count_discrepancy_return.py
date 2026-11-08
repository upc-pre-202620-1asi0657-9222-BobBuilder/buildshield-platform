"""E2E por el gateway (http://localhost:8080): discrepancia manual, devolución de saldos y conteo con revisión.

Recorre los endpoints actuales de discrepancy-service e inventory-service. Termina con código 1 en la primera falla.
"""
import datetime
import random
import sys

from api_flow_ordering_inventory import LOG, call, retry, until


def login(email, password):
    return call("POST", "/api/v1/auth/sign-in", {"email": email, "password": password}, expect=200)[1]["accessToken"]


def prepare():
    """Organización nueva con obra, almacén, material y un encargado asignado a cada lugar."""
    run = random.randint(100000000, 999999999)
    password = "Segura123"
    admin_email = f"ana.{run}@andina.pe"
    call("POST", "/api/v1/auth/sign-up", {"ruc": f"20{run}", "legalName": f"Constructora Saldos {run} SAC",
                                         "adminFullName": "Ana Torres", "adminEmail": admin_email,
                                         "password": password}, expect=201)
    admin = login(admin_email, password)
    _, site_user = call("POST", "/api/v1/users", {"fullName": "Jorge Huaman", "email": f"jorge.{run}@andina.pe",
                                                 "role": "SITE_MANAGER", "password": password}, admin, expect=201)
    _, wh_user = call("POST", "/api/v1/users", {"fullName": "Rosa Quispe", "email": f"rosa.{run}@andina.pe",
                                               "role": "WAREHOUSE_MANAGER", "password": password}, admin, expect=201)
    _, worksite = call("POST", "/api/v1/worksites", {"name": "Torre Norte", "address": "Av. Javier Prado 123",
                                                    "district": "San Isidro", "city": "Lima",
                                                    "startDate": datetime.date.today().isoformat()}, admin, expect=201)
    _, warehouse = call("POST", "/api/v1/warehouses", {"name": "Almacén Central", "type": "WAREHOUSE",
                                                      "address": "Av. Argentina 2500, Callao"}, admin, expect=201)
    _, material = call("POST", "/api/v1/materials", {"sku": f"CEM-{run}", "name": "Cemento Portland tipo I",
                                                    "unit": "BAG", "wasteTolerancePercent": 2.5}, admin, expect=201)
    # organization conoce a los usuarios por el evento UserCreated: puede tardar un momento.
    retry("POST", "/api/v1/assignments", {"userId": site_user["id"], "siteType": "WORKSITE", "siteId": worksite["id"]},
          admin, 201)
    retry("POST", "/api/v1/assignments", {"userId": wh_user["id"], "siteType": "WAREHOUSE", "siteId": warehouse["id"]},
          admin, 201)
    return {
        "admin": admin,
        "site": login(f"jorge.{run}@andina.pe", password),
        "wh": login(f"rosa.{run}@andina.pe", password),
        "worksite": worksite["id"],
        "warehouse": warehouse["id"],
        "material": material["id"],
    }


def warehouse_available(ctx):
    _, rows = call("GET", f"/api/v1/stock?warehouseId={ctx['warehouse']}", token=ctx["wh"], expect=200)
    return next((float(row["availableQty"]) for row in rows if row["materialId"] == ctx["material"]), 0.0)


def worksite_available(ctx):
    _, rows = call("GET", f"/api/v1/stock/worksites?worksiteId={ctx['worksite']}", token=ctx["site"], expect=200)
    return float(rows[0]["availableQty"]) if rows else 0.0


def deliver_to_worksite(ctx):
    """100 bolsas en el almacén, se despachan 40 y la obra confirma 37: la merma abre una discrepancia automática."""
    site, wh = ctx["site"], ctx["wh"]
    retry("POST", "/api/v1/stock/entries", {"warehouseId": ctx["warehouse"], "materialId": ctx["material"],
                                            "quantity": 100, "note": "Guía 001"}, wh, 201)
    required = (datetime.date.today() + datetime.timedelta(days=14)).isoformat()
    order = retry("POST", "/api/v1/orders", {"worksiteId": ctx["worksite"], "warehouseId": ctx["warehouse"],
                                             "requiredDate": required,
                                             "lines": [{"materialId": ctx["material"], "quantity": 40}]},
                  site, 201, idem=True)
    retry("POST", f"/api/v1/orders/{order['id']}/approve", None, wh, 200, idem=True)
    until("pedido IN_REVIEW tras StockReserved",
          lambda: call("GET", f"/api/v1/orders/{order['id']}", token=site)[1]["status"] == "IN_REVIEW")
    _, dispatch = call("POST", "/api/v1/dispatches", {"orderId": order["id"], "lines": [
        {"orderLineId": order["lines"][0]["id"], "quantity": 40}]}, wh, idem=True, expect=201)
    call("PATCH", f"/api/v1/dispatches/{dispatch['id']}/carrier", {"carrierName": "Transportes Rímac SAC",
                                                                   "carrierDocument": "20555666777",
                                                                   "plate": "ABC-123"}, wh, expect=200)
    call("POST", f"/api/v1/dispatches/{dispatch['id']}/departure-weighing", {"grossKg": 2550.5, "tareKg": 550.5}, wh,
         expect=200)
    call("POST", f"/api/v1/dispatches/{dispatch['id']}/depart", None, wh, idem=True, expect=200)
    until("almacén con 60 tras la salida", lambda: warehouse_available(ctx) == 60)
    _, reception = call("POST", "/api/v1/receptions", {"dispatchId": dispatch["id"]}, site, expect=201)
    call("PUT", f"/api/v1/receptions/{reception['id']}/lines/{reception['lines'][0]['id']}", {"receivedQty": 37}, site,
         expect=200)
    call("POST", f"/api/v1/receptions/{reception['id']}/confirm", None, site, idem=True, expect=200)
    until("obra con 37 tras la conformidad", lambda: worksite_available(ctx) == 37)
    return dispatch["id"], reception["id"]


def manual_discrepancy(ctx, dispatch_id, reception_id):
    site, wh, admin = ctx["site"], ctx["wh"], ctx["admin"]
    automatic = until("discrepancia automática por la merma", lambda: call(
        "GET", f"/api/v1/discrepancies?dispatchId={dispatch_id}", token=site, expect=200)[1])
    assert automatic[0]["type"] == "SHRINKAGE", automatic

    body = {"receptionId": reception_id, "materialId": ctx["material"], "type": "DAMAGE", "quantity": 2,
            "observation": "Dos bolsas rotas en la descarga"}
    status, error = call("POST", "/api/v1/discrepancies", body, site)
    assert status == 400 and error["code"] == "IDEMPOTENCY_KEY_REQUIRED", error
    call("POST", "/api/v1/discrepancies", body, wh, idem=True, expect=403)
    # discrepancy conoce la recepción por el evento ReceptionConfirmed: puede tardar un momento.
    manual = retry("POST", "/api/v1/discrepancies", body, site, 201, idem=True)
    assert manual["type"] == "DAMAGE" and manual["status"] == "OPEN", manual
    assert manual["manifestCode"], manual
    _, conflict = call("POST", "/api/v1/discrepancies", body, site, idem=True, expect=409)
    assert conflict["code"] == "DISCREPANCY_ALREADY_OPEN", conflict

    path = f"/api/v1/discrepancies/{manual['id']}"
    _, responded = call("POST", f"{path}/response", {"text": "Se repone mañana"}, wh, idem=True, expect=200)
    assert responded["status"] == "RESPONDED", responded
    _, escalated = call("POST", f"{path}/escalate", {"reason": "La reposición no llegó"}, site, idem=True, expect=200)
    assert escalated["status"] == "ESCALATED", escalated
    _, resolved = call("POST", f"{path}/resolve", {"decision": "Se descuenta al transportista"}, admin, idem=True,
                       expect=200)
    assert resolved["status"] == "RESOLVED", resolved

    other = f"/api/v1/discrepancies/{automatic[0]['id']}"
    call("POST", f"{other}/response", {"text": "Se revisa con el transportista"}, wh, idem=True, expect=200)
    _, accepted = call("POST", f"{other}/accept", None, site, idem=True, expect=200)
    assert accepted["status"] == "ACCEPTED", accepted


def material_return(ctx):
    site, wh = ctx["site"], ctx["wh"]
    balance = until("saldo de la obra con su almacén de origen", lambda: (
        lambda lines: lines if lines and lines[0]["originWarehouses"] else None
    )(call("GET", f"/api/v1/stock/worksites/{ctx['worksite']}/balance", token=site, expect=200)[1]["lines"]))
    assert float(balance[0]["returnableQty"]) == 37, balance

    def register(quantity):
        return {"worksiteId": ctx["worksite"], "lines": [{"materialId": ctx["material"], "quantity": quantity,
                                                          "detail": "Bolsas cerradas"}],
                "note": "Saldo al cierre del vaciado"}

    _, excess = call("POST", "/api/v1/stock/returns", register(999), site, expect=409)
    assert excess["code"] == "RETURN_EXCEEDS_BALANCE", excess
    call("POST", "/api/v1/stock/returns", register(1), wh, expect=403)

    # Rechazada por el almacén.
    _, rejected = call("POST", "/api/v1/stock/returns", register(3), site, expect=201)
    call("POST", f"/api/v1/stock/returns/{rejected['id']}/request", None, site, expect=200)
    _, rejected = call("POST", f"/api/v1/stock/returns/{rejected['id']}/reject",
                       {"reason": "El material es de otra obra"}, wh, expect=200)
    assert rejected["status"] == "REJECTED" and rejected["hasRejections"], rejected

    # Anulada por la obra.
    _, cancelled = call("POST", "/api/v1/stock/returns", register(2), site, expect=201)
    _, cancelled = call("POST", f"/api/v1/stock/returns/{cancelled['id']}/cancel", None, site, expect=200)
    assert cancelled["status"] == "CANCELLED", cancelled

    # Completa: se acepta una parte y el resto queda rechazado con su motivo.
    _, created = call("POST", "/api/v1/stock/returns", register(12), site, expect=201)
    assert created["status"] == "REGISTERED" and created["warehouseId"] == ctx["warehouse"], created
    path = f"/api/v1/stock/returns/{created['id']}"
    _, requested = call("POST", f"{path}/request", None, site, expect=200)
    assert requested["status"] == "REQUESTED", requested
    call("POST", f"{path}/approve", None, site, expect=403)
    _, approved = call("POST", f"{path}/approve", None, wh, expect=200)
    assert approved["status"] == "APPROVED", approved
    _, in_transit = call("POST", f"{path}/dispatch", None, site, expect=200)
    assert in_transit["status"] == "IN_TRANSIT", in_transit
    assert worksite_available(ctx) == 25
    _, incomplete = call("POST", f"{path}/receive", {"lines": [{"materialId": ctx["material"], "acceptedQty": 10}]}, wh,
                         expect=400)
    assert incomplete["code"] == "REJECTION_REASON_REQUIRED", incomplete
    _, received = call("POST", f"{path}/receive", {"lines": [{"materialId": ctx["material"], "acceptedQty": 10,
                                                              "rejectionReason": "Bolsas húmedas, no aptas"}]}, wh,
                       expect=200)
    assert received["status"] == "RECEIVED" and received["hasRejections"], received
    assert float(received["lines"][0]["acceptedQty"]) == 10 and float(received["lines"][0]["rejectedQty"]) == 2, received
    assert warehouse_available(ctx) == 70
    _, listed = call("GET", f"/api/v1/stock/returns?worksiteId={ctx['worksite']}", token=wh, expect=200)
    assert {row["status"] for row in listed} == {"REJECTED", "CANCELLED", "RECEIVED"}, listed


def stock_count(ctx):
    wh, site = ctx["wh"], ctx["site"]
    start = {"warehouseId": ctx["warehouse"], "materialIds": [ctx["material"]], "note": "Conteo mensual de cemento"}
    call("GET", f"/api/v1/stock/counts?warehouseId={ctx['warehouse']}", token=site, expect=403)

    # Con diferencias: revisión obligatoria y luego el ajuste.
    _, count = call("POST", "/api/v1/stock/counts", start, wh, expect=201)
    assert count["status"] == "IN_PROGRESS", count
    path = f"/api/v1/stock/counts/{count['id']}"
    _, already = call("POST", "/api/v1/stock/counts", start, wh, expect=409)
    assert already["code"] == "COUNT_ALREADY_OPEN", already
    _, incomplete = call("POST", f"{path}/finish", None, wh, expect=409)
    assert incomplete["code"] == "COUNT_INCOMPLETE", incomplete
    call("PUT", f"{path}/lines", {"lines": [{"materialId": ctx["material"], "countedQty": 65}]}, wh, expect=200)
    _, finished = call("POST", f"{path}/finish", None, wh, expect=200)
    assert finished["status"] == "DIFFERENCES_FOUND" and finished["differenceCount"] == 1, finished
    line = finished["lines"][0]
    assert float(line["systemQty"]) == 70 and float(line["difference"]) == -5, line
    _, early = call("POST", f"{path}/adjustment", {"reason": "Rotura de bolsas"}, wh, expect=409)
    assert early["code"] == "COUNT_NOT_REVIEWED", early
    assert warehouse_available(ctx) == 70
    _, reviewed = call("POST", f"{path}/review", {"note": "Se recontó dos veces; faltan 5 bolsas"}, wh, expect=200)
    assert reviewed["status"] == "REVIEWED" and reviewed["reviewNote"], reviewed
    _, adjusted = call("POST", f"{path}/adjustment", {"reason": "Rotura de bolsas en el almacén"}, wh, expect=200)
    assert adjusted["status"] == "ADJUSTED" and adjusted["adjustmentReason"], adjusted
    assert warehouse_available(ctx) == 65
    _, movements = call("GET", f"/api/v1/stock/movements?locationId={ctx['warehouse']}", token=wh, expect=200)
    assert "ADJUSTMENT_OUT" in {movement["type"] for movement in movements}, movements

    # Sin diferencias: queda cerrado sin revisión.
    _, matched = call("POST", "/api/v1/stock/counts", start, wh, expect=201)
    call("PUT", f"/api/v1/stock/counts/{matched['id']}/lines",
         {"lines": [{"materialId": ctx["material"], "countedQty": 65}]}, wh, expect=200)
    _, matched = call("POST", f"/api/v1/stock/counts/{matched['id']}/finish", None, wh, expect=200)
    assert matched["status"] == "MATCHED", matched

    # Anulado: no cambia el stock.
    _, cancelled = call("POST", "/api/v1/stock/counts", start, wh, expect=201)
    _, cancelled = call("POST", f"/api/v1/stock/counts/{cancelled['id']}/cancel", None, wh, expect=200)
    assert cancelled["status"] == "CANCELLED", cancelled
    assert warehouse_available(ctx) == 65


def main():
    ctx = prepare()
    dispatch_id, reception_id = deliver_to_worksite(ctx)
    manual_discrepancy(ctx, dispatch_id, reception_id)
    material_return(ctx)
    stock_count(ctx)
    print("\nRESULTADO: flujo completo OK,", len(LOG), "peticiones")


if __name__ == "__main__":
    try:
        main()
    except (SystemExit, AssertionError) as failure:
        print("FALLO:", failure)
        sys.exit(1)
