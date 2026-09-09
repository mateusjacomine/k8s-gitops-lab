#!/usr/bin/env bash
# Roda os testes da app num venv persistente do WSL.
set -u
VENV=/opt/venv-cicd
APP=/mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/cicd/app

command -v python3 >/dev/null || { echo "python3 ausente"; exit 1; }
[ -d "$VENV" ] || python3 -m venv "$VENV" 2>/dev/null || {
  apt-get install -y -qq python3.12-venv >/dev/null 2>&1
  python3 -m venv "$VENV"
}
"$VENV/bin/pip" install -q -r "$APP/requirements.txt" pytest httpx 2>&1 | tail -2

cd "$APP" || exit 1
"$VENV/bin/python" -m pytest test_main.py -q "$@"
