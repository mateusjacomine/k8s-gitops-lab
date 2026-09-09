#!/usr/bin/env python3
"""
Analisador de Pods — exercicio no formato pedido pela vaga.

Filtra pods por restart_count e janela temporal, tratando os casos de borda que
o entrevistador vai testar: listas vazias, campos ausentes, timestamps em
formatos diferentes, pods sem containerStatuses.

Uso:
    python pod_analyzer.py pods.json --min-restarts 5 --since-hours 24
    kubectl get pods -A -o json | python pod_analyzer.py - --min-restarts 5
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable, Iterator


# --------------------------------------------------------------------------
# Parsing de tempo: o ponto onde a maioria dos candidatos escorrega.
# A API do Kubernetes devolve RFC3339 com 'Z' (ex: 2026-09-07T18:47:18Z).
# datetime.fromisoformat() so aceita 'Z' a partir do Python 3.11, entao
# normalizamos para manter compatibilidade e SEMPRE devolvemos aware-datetime.
# --------------------------------------------------------------------------
def parse_k8s_timestamp(value: Any) -> datetime | None:
    if not value or not isinstance(value, str):
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    # Se vier sem timezone, assume UTC (comportamento da API)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


@dataclass
class PodReport:
    namespace: str
    name: str
    phase: str
    restarts: int
    age_hours: float | None
    node: str | None
    problem_containers: list[str] = field(default_factory=list)
    last_reasons: list[str] = field(default_factory=list)

    def to_row(self) -> str:
        age = f"{self.age_hours:.1f}h" if self.age_hours is not None else "?"
        reasons = ",".join(sorted(set(self.last_reasons))) or "-"
        return (
            f"{self.namespace:<20} {self.name:<40} {self.phase:<10} "
            f"{self.restarts:>8} {age:>8}  {reasons}"
        )


def iter_pods(payload: Any) -> Iterator[dict]:
    """Aceita tanto uma PodList quanto um unico Pod ou uma lista crua."""
    if payload is None:
        return
    if isinstance(payload, list):
        for item in payload:
            if isinstance(item, dict):
                yield item
        return
    if not isinstance(payload, dict):
        return
    kind = payload.get("kind")
    if kind == "Pod":
        yield payload
    else:
        # PodList (ou qualquer coisa com .items) — items pode ser None
        for item in payload.get("items") or []:
            if isinstance(item, dict):
                yield item


def analyze_pod(pod: dict, now: datetime) -> PodReport | None:
    """Extrai o relatorio de um pod. Retorna None se o objeto for inutilizavel."""
    metadata = pod.get("metadata") or {}
    name = metadata.get("name")
    if not name:
        return None  # sem nome nao ha o que reportar

    status = pod.get("status") or {}
    spec = pod.get("spec") or {}

    # containerStatuses some enquanto o pod esta Pending — precisa do 'or []'
    container_statuses = status.get("containerStatuses") or []
    init_statuses = status.get("initContainerStatuses") or []

    total_restarts = 0
    problems: list[str] = []
    reasons: list[str] = []

    for cs in list(container_statuses) + list(init_statuses):
        if not isinstance(cs, dict):
            continue
        count = cs.get("restartCount")
        if isinstance(count, int):
            total_restarts += count

        cname = cs.get("name", "?")
        if not cs.get("ready", True):
            problems.append(cname)

        # Motivo do ultimo encerramento (OOMKilled, Error, Completed...)
        state = cs.get("lastState") or {}
        terminated = state.get("terminated") or {}
        reason = terminated.get("reason")
        if reason:
            reasons.append(reason)
        exit_code = terminated.get("exitCode")
        if exit_code == 137 and "OOMKilled" not in reasons:
            reasons.append("ExitCode137")

        # Motivo de estar preso em Waiting (ImagePullBackOff, CrashLoopBackOff)
        waiting = (cs.get("state") or {}).get("waiting") or {}
        if waiting.get("reason"):
            reasons.append(waiting["reason"])

    created = parse_k8s_timestamp(metadata.get("creationTimestamp"))
    age_hours = (now - created).total_seconds() / 3600 if created else None

    return PodReport(
        namespace=metadata.get("namespace") or "default",
        name=name,
        phase=status.get("phase") or "Unknown",
        restarts=total_restarts,
        age_hours=age_hours,
        node=spec.get("nodeName"),
        problem_containers=problems,
        last_reasons=reasons,
    )


def filter_pods(
    pods: Iterable[dict],
    min_restarts: int = 0,
    since_hours: float | None = None,
    phases: set[str] | None = None,
    now: datetime | None = None,
) -> list[PodReport]:
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(hours=since_hours) if since_hours else None

    results: list[PodReport] = []
    for pod in pods:
        report = analyze_pod(pod, now)
        if report is None:
            continue
        if report.restarts < min_restarts:
            continue
        if phases and report.phase not in phases:
            continue
        if cutoff is not None:
            # age_hours None = sem timestamp; nao da para afirmar que esta na
            # janela, entao excluimos (decisao explicita, vale comentar na call)
            if report.age_hours is None or report.age_hours > since_hours:
                continue
        results.append(report)

    # Mais reinicios primeiro; desempata por namespace/nome para saida estavel
    results.sort(key=lambda r: (-r.restarts, r.namespace, r.name))
    return results


def load_payload(path: str) -> Any:
    if path == "-":
        raw = sys.stdin.read()
    else:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    # lstrip do BOM: aparece quando o JSON vem por pipe do PowerShell
    raw = raw.lstrip("﻿")
    if not raw.strip():
        return None
    return json.loads(raw)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Filtra pods por restarts e idade")
    parser.add_argument("source", help="arquivo JSON ou '-' para stdin")
    parser.add_argument("--min-restarts", type=int, default=5)
    parser.add_argument("--since-hours", type=float, default=None)
    parser.add_argument("--phase", action="append", dest="phases")
    parser.add_argument("--json", action="store_true", help="saida em JSON")
    args = parser.parse_args(argv)

    try:
        payload = load_payload(args.source)
    except FileNotFoundError:
        print(f"erro: arquivo nao encontrado: {args.source}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"erro: JSON invalido ({exc})", file=sys.stderr)
        return 2

    reports = filter_pods(
        iter_pods(payload),
        min_restarts=args.min_restarts,
        since_hours=args.since_hours,
        phases=set(args.phases) if args.phases else None,
    )

    if args.json:
        print(json.dumps([r.__dict__ for r in reports], indent=2, default=str))
        return 0

    if not reports:
        print("Nenhum pod bateu os criterios.")
        return 0

    print(f"{'NAMESPACE':<20} {'POD':<40} {'PHASE':<10} {'RESTARTS':>8} {'AGE':>8}  REASONS")
    for report in reports:
        print(report.to_row())
    print(f"\n{len(reports)} pod(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
