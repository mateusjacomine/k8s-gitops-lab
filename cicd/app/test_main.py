"""Testes que rodam no CI antes de qualquer build."""
import os

from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_ready_apos_startup():
    # O lifespan so roda dentro do context manager — e assim que se testa
    # readiness de verdade, em vez de assumir que o app ja subiu.
    with TestClient(app) as c:
        r = c.get("/ready")
        assert r.status_code == 200
        assert r.json()["status"] == "ready"


def test_ready_503_antes_do_startup():
    """Sem o lifespan, /ready deve recusar trafego."""
    r = client.get("/ready")
    assert r.status_code == 503


def test_root_tem_versao():
    r = client.get("/")
    assert r.status_code == 200
    assert "version" in r.json()


def test_work_respeita_ms():
    r = client.get("/work?ms=10")
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_metrics_expoe_prometheus():
    client.get("/health")          # gera pelo menos uma amostra
    r = client.get("/metrics")
    assert r.status_code == 200
    corpo = r.text
    # As metricas que os dashboards e alertas dependem
    assert "http_request_duration_seconds" in corpo
    assert "http_requests_total" in corpo
    assert "app_info" in corpo


def test_metrics_nao_explode_cardinalidade():
    """Path com parametro deve agrupar pela rota, nao pelo valor concreto."""
    for ms in (1, 2, 3):
        client.get(f"/work?ms={ms}")
    corpo = client.get("/metrics").text
    # query string nao pode virar label
    assert "ms=1" not in corpo


def test_label_route_e_nao_endpoint():
    """
    O Prometheus Operator injeta um label 'endpoint' com o nome da porta do
    Service. Se a app tambem usar 'endpoint', o do Operator vence e todas as
    rotas colapsam num unico valor, quebrando as queries por rota.
    """
    client.get("/health")
    corpo = client.get("/metrics").text
    assert 'route="/health"' in corpo
    assert 'endpoint="/health"' not in corpo


def test_version_nunca_vazia():
    """
    Regressao: APP_VERSION definido porem VAZIO fazia o FastAPI abortar no
    import com AssertionError, causando CrashLoopBackOff no cluster.
    O default do os.getenv nao cobre esse caso — so cobre variavel ausente.

    Roda em subprocesso: recarregar o modulo no processo atual quebraria o
    registry global do prometheus_client (metricas duplicadas).
    """
    import subprocess
    import sys

    codigo = (
        "import os; os.environ['APP_VERSION'] = ''; "
        "import main; "
        "assert main.VERSION, 'VERSION vazia'; "
        "assert main.app.version, 'app.version vazia'; "
        "print('ok')"
    )
    r = subprocess.run(
        [sys.executable, "-c", codigo],
        capture_output=True, text=True, cwd=os.path.dirname(os.path.abspath(__file__)),
    )
    assert r.returncode == 0, "app nao sobe com APP_VERSION vazia: " + r.stderr[-600:]
