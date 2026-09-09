#!/usr/bin/env bash
# Exercita o worker pool: caminho normal, cancelamento por context e lista vazia.
cd "$(dirname "$0")" || exit 1

go build -o ./podcheck . || exit 1

echo "=== normal (4 workers) ==="
./podcheck -workers 4 -timeout 5s

echo
echo "=== timeout 200ms: cancelamento por context ==="
./podcheck -workers 2 -timeout 200ms 2>&1 | tail -5

echo
echo "=== lista vazia ==="
echo '[]' > /tmp/v.json
./podcheck -input /tmp/v.json
echo "exit=$?"

echo
echo "=== um alvo saudavel ==="
echo '[{"Namespace":"prod","Pod":"only-one","Restarts":0}]' > /tmp/one.json
./podcheck -input /tmp/one.json
echo "exit=$?"

rm -f ./podcheck
