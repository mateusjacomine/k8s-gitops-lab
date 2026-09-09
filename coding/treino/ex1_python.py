#!/usr/bin/env python3
"""
EXERCICIO 1 — 20 minutos, sem consultar nada.

Implemente filtrar() para devolver os pods com restarts >= min_restarts,
ordenados do maior para o menor.

Cada item devolvido deve ser um dict com: namespace, name, restarts, phase.

Rode:  python ex1_python.py
Os testes no final dizem se passou.
"""
import json
import os


def filtrar(payload, min_restarts=5):
    resultado = []

    for pod in (payload.get("items") or []):
        metadata = pod.get("metadata") or {}
        status = pod.get("status") or {}

        restarts = sum(
            container.get("restartCount", 0)
            for container in (status.get("containerStatuses") or [])
        )

        if restarts >= min_restarts:
            resultado.append({
                "namespace": metadata.get("namespace"),
                "name": metadata.get("name"),
                "restarts": restarts,
                "phase": status.get("phase")
            })

    return sorted(
        resultado,
        key=lambda x: x["restarts"],
        reverse=True
    )

# ---------------------------------------------------------------------------
# TESTES — nao edite
# ---------------------------------------------------------------------------
def _testes():
    base = os.path.join(os.path.dirname(__file__), "..", "python", "sample_pods.json")
    with open(base, encoding="utf-8") as fh:
        dados = json.load(fh)

    falhas = []

    # 1) caso principal
    try:
        r = filtrar(dados, 5)
    except Exception as exc:
        print("=" * 60)
        print(f"FALHOU no caso principal: {type(exc).__name__}: {exc}")
        if isinstance(exc, KeyError):
            print("  DICA: use .get(...) or [] — campos da API do K8s podem faltar")
        print("=" * 60)
        return False
    if len(r) != 4:
        falhas.append(f"esperado 4 pods com >=5 restarts, veio {len(r)}")
    else:
        if [p["restarts"] for p in r] != [12, 9, 8, 7]:
            falhas.append(f"ordenacao errada: {[p['restarts'] for p in r]}")
        if r[0]["name"] != "api-gateway-7d9f8b-x2k4l":
            falhas.append(f"primeiro deveria ser api-gateway, veio {r[0]['name']}")
        if r[0]["namespace"] != "production":
            falhas.append("namespace nao preenchido corretamente")

    # 2) edge cases — aqui é onde a maioria quebra
    for nome, entrada in [
        ("dict vazio", {}),
        ("items null", {"items": None}),
        ("items vazio", {"items": []}),
    ]:
        try:
            out = filtrar(entrada, 5)
            if out != []:
                falhas.append(f"{nome}: esperado [], veio {out}")
        except Exception as exc:
            falhas.append(f"{nome}: levantou {type(exc).__name__}: {exc}")

    # 3) pod sem containerStatuses (Pending)
    try:
        out = filtrar({"items": [{"metadata": {"name": "p"}, "status": {"phase": "Pending"}}]}, 0)
        if len(out) != 1 or out[0]["restarts"] != 0:
            falhas.append(f"pod sem containerStatuses: esperado restarts=0, veio {out}")
    except Exception as exc:
        falhas.append(f"pod sem containerStatuses: levantou {type(exc).__name__}")

    # 4) soma de multiplos containers
    try:
        out = filtrar({"items": [{
            "metadata": {"name": "multi", "namespace": "x"},
            "status": {"phase": "Running", "containerStatuses": [
                {"restartCount": 3}, {"restartCount": 4}]},
        }]}, 5)
        if len(out) != 1 or out[0]["restarts"] != 7:
            falhas.append(f"soma de containers: esperado 7, veio {out}")
    except Exception as exc:
        falhas.append(f"soma de containers: levantou {type(exc).__name__}")

    print("=" * 60)
    if falhas:
        print(f"FALHOU ({len(falhas)}):")
        for f in falhas:
            print("  -", f)
    else:
        print("PASSOU — todos os casos, inclusive os de borda.")
    print("=" * 60)
    return not falhas


if __name__ == "__main__":
    try:
        ok = _testes()
    except NotImplementedError as exc:
        print(f"\n{exc}\n")
        ok = False
    raise SystemExit(0 if ok else 1)
