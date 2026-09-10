"""
API de demonstracao para a esteira GitOps.

Expoe o que uma aplicacao de plataforma precisa expor:
  /health   -> liveness  (esta viva?)
  /ready    -> readiness (pode receber trafego?)
  /metrics  -> metricas Prometheus (latencia, contadores)
  /work     -> endpoint com latencia artificial, para demonstrar p95/p99
"""
import os
import random
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

# or "dev" cobre APP_VERSION definido porem VAZIO — o default do getenv
# so age quando a variavel nao existe. FastAPI recusa version vazia.
VERSION = os.getenv("APP_VERSION") or "dev"
# Simula app com boot lento — e o motivo de existir startupProbe
BOOT_DELAY = float(os.getenv("BOOT_DELAY_SECONDS", "0"))

# --- Metricas ---------------------------------------------------------------
# Buckets escolhidos para dar resolucao em p95/p99 na faixa de ms que importa.
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Latencia das requisicoes HTTP",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total de requisicoes HTTP",
    ["method", "route", "status"],
)
APP_INFO = Gauge("app_info", "Metadados da aplicacao", ["version"])
READY = Gauge("app_ready", "1 quando a aplicacao esta pronta")

APP_INFO.labels(version=VERSION).set(1)
READY.set(0)

_started_at = time.time()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Marca ready so depois do boot: e isso que a readinessProbe observa.
    # lifespan substitui @app.on_event, que esta deprecado no FastAPI atual.
    if BOOT_DELAY > 0:
        time.sleep(BOOT_DELAY)
    READY.set(1)
    yield
    READY.set(0)


app = FastAPI(title="demo-api", version=VERSION, lifespan=lifespan)


@app.middleware("http")
async def track_metrics(request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start

    # Usa a rota registrada (/items/{id}), nao o path concreto, para nao
    # explodir a cardinalidade da metrica.
    # Label 'route' e nao 'endpoint': o Prometheus Operator injeta um label
    # 'endpoint' com o nome da porta do Service, sobrescrevendo o nosso.
    matched = request.scope.get("route")
    route = getattr(matched, "path", request.url.path)

    REQUEST_LATENCY.labels(request.method, route).observe(elapsed)
    REQUEST_COUNT.labels(request.method, route, response.status_code).inc()
    return response


@app.get("/")
def root():
    return {"app": "demo-api", "version": VERSION, "uptime_s": round(time.time() - _started_at, 1)}


@app.get("/health")
def health():
    """Liveness: responde enquanto o processo estiver vivo."""
    return {"status": "ok"}


@app.get("/ready")
def ready():
    """Readiness: 503 enquanto nao terminou o boot."""
    if READY._value.get() < 1:
        return Response(content='{"status":"starting"}', status_code=503,
                        media_type="application/json")
    return {"status": "ready"}


@app.get("/work")
def work(ms: int = 0):
    """
    Latencia artificial para demonstrar p95/p99 no Grafana.
      /work         -> latencia aleatoria (cauda longa ocasional)
      /work?ms=800  -> latencia fixa de 800ms
    """
    if ms > 0:
        time.sleep(ms / 1000)
    else:
        # 5% das requisicoes sao lentas: cria a cauda que separa p50 de p99
        time.sleep(random.uniform(0.6, 1.2) if random.random() < 0.05
                   else random.uniform(0.01, 0.08))
    return {"ok": True, "version": VERSION}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
