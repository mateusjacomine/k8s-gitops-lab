#!/usr/bin/env bash
# Valida sua implementacao dos exercicios.
#   bash validar.sh py    -> exercicio Python
#   bash validar.sh go    -> exercicio Go
#   bash validar.sh       -> os dois
DIR="$(cd "$(dirname "$0")" && pwd)"

rodar_py() {
  echo "########## EXERCICIO 1 — PYTHON ##########"
  ( cd "$DIR" && python3 ex1_python.py 2>&1 || python ex1_python.py 2>&1 )
}

rodar_go() {
  echo "########## EXERCICIO 3 — GO ##########"
  cd "$DIR/go" || return 1
  [ -f go.mod ] || go mod init treino >/dev/null 2>&1
  echo "--- go vet ---"
  go vet ./... 2>&1 && echo "vet OK"
  echo "--- go test -race ---"
  timeout 120 go test -race ./... 2>&1 | grep -vE '^\s*$' | head -30
}

case "${1:-todos}" in
  py|python) rodar_py ;;
  go)        rodar_go ;;
  *)         rodar_py; echo; rodar_go ;;
esac
