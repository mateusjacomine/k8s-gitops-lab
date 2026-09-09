# Esqueletos para Codar do Zero

> O código em `main.go` e `pod_analyzer.py` tem ~230 linhas. **Você não vai
> escrever isso em 25 minutos.** Estes esqueletos são o que realmente cabe:
> o núcleo que resolve o problema, sem enfeite.
>
> Estratégia: escreva o mínimo que roda, diga em voz alta o que *acrescentaria*
> com mais tempo. Isso pontua mais que código pela metade.

---

# PYTHON

## O esqueleto mínimo (memorize este)

```python
import json
from datetime import datetime, timedelta, timezone

def parse_ts(value):
    """API do K8s devolve '2026-09-07T18:47:18Z'."""
    if not value:
        return None
    # fromisoformat só aceita 'Z' no Python 3.11+; normalizar é mais seguro
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None

def filtrar(payload, min_restarts=5, since_hours=None):
    agora = datetime.now(timezone.utc)
    corte = agora - timedelta(hours=since_hours) if since_hours else None
    saida = []

    for pod in (payload.get("items") or []):          # <- 'or []' é o ponto-chave
        meta = pod.get("metadata") or {}
        status = pod.get("status") or {}

        restarts = sum(
            cs.get("restartCount", 0)
            for cs in (status.get("containerStatuses") or [])
        )
        if restarts < min_restarts:
            continue

        criado = parse_ts(meta.get("creationTimestamp"))
        if corte and (criado is None or criado < corte):
            continue

        saida.append({
            "namespace": meta.get("namespace", "default"),
            "name": meta.get("name"),
            "restarts": restarts,
            "phase": status.get("phase"),
        })

    saida.sort(key=lambda p: -p["restarts"])
    return saida

if __name__ == "__main__":
    with open("pods.json") as fh:
        dados = json.load(fh)
    for p in filtrar(dados, min_restarts=5):
        print(f"{p['namespace']:<15} {p['name']:<40} {p['restarts']:>3}")
```

**~45 linhas. Isso cabe em 25 minutos.**

## O que dizer enquanto escreve

| Ao escrever | Fale |
|---|---|
| `payload.get("items") or []` | *"`items` pode vir `null`; `or []` cobre ausente e nulo de uma vez"* |
| `status.get("containerStatuses") or []` | *"enquanto o pod está Pending esse campo nem existe"* |
| `parse_ts` | *"a API devolve RFC3339 com Z; `fromisoformat` só aceita Z a partir do 3.11"* |
| `criado is None` | *"sem timestamp eu excluo — decisão explícita, poderia ser o contrário"* |
| `sort(key=lambda p: -p[...])` | *"pior primeiro, que é o que interessa em triagem"* |

## Se sobrar tempo, ofereça (não faça sem pedirem)

```python
# motivo do último encerramento — é onde aparece OOMKilled
for cs in (status.get("containerStatuses") or []):
    term = (cs.get("lastState") or {}).get("terminated") or {}
    if term.get("reason"):
        motivos.append(term["reason"])
```

## Concorrência em Python — se pedirem

```python
# I/O-bound (chamar vários clusters/endpoints): threads
from concurrent.futures import ThreadPoolExecutor

with ThreadPoolExecutor(max_workers=8) as ex:
    resultados = list(ex.map(checar_endpoint, urls))
```

```python
# asyncio, se a lib for async
import asyncio

async def main(urls):
    tarefas = [checar(u) for u in urls]
    return await asyncio.gather(*tarefas, return_exceptions=True)
```

**A frase:** *"parsear JSON de pods é I/O-bound — o tempo é esperar o API server.
Threads ou asyncio resolvem. `multiprocessing` só se fosse cálculo pesado, porque
é o único jeito de escapar do GIL."*

---

# GO

## O esqueleto mínimo (memorize este)

```go
package main

import (
	"context"
	"fmt"
	"sync"
	"time"
)

type Result struct {
	Item string
	Err  error
}

func worker(ctx context.Context, item string) (string, error) {
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case <-time.After(100 * time.Millisecond):   // trabalho simulado
		return item + "-ok", nil
	}
}

func main() {
	items := []string{"a", "b", "c", "d", "e"}
	workers := 3

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	jobs := make(chan string)
	results := make(chan Result, len(items))   // buffer: worker nunca bloqueia

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for it := range jobs {              // sai quando jobs fecha
				v, err := worker(ctx, it)
				results <- Result{Item: v, Err: err}
			}
		}()
	}

	// produtor
	go func() {
		defer close(jobs)                       // ESSENCIAL: solta os workers
		for _, it := range items {
			select {
			case jobs <- it:
			case <-ctx.Done():
				return
			}
		}
	}()

	// fecha results só depois que TODOS os workers saírem
	go func() {
		wg.Wait()
		close(results)
	}()

	var ok, falhas int
	for r := range results {
		if r.Err != nil {
			falhas++
			fmt.Println("erro:", r.Err)
			continue
		}
		ok++
		fmt.Println(r.Item)
	}
	fmt.Printf("ok=%d falhas=%d\n", ok, falhas)
}
```

**~60 linhas. Cabe em 25 minutos se você treinar.**

## Os 4 pontos que TODO entrevistador cobra

1. **`close(jobs)`** — sem isso o `for range jobs` nunca termina → deadlock.
2. **`wg.Wait()` em goroutine separada** — se chamasse na main antes do
   `range results`, os workers travariam escrevendo num canal sem leitor.
3. **`defer wg.Done()`** — garante o decremento mesmo com panic/return cedo.
4. **`ctx.Done()` no produtor e no worker** — cancelamento de verdade, não só
   esperar o timer acabar.

## Erros que derrubam candidato

```go
// ERRADO — Go < 1.22: todas as goroutines veem o último valor
for _, it := range items {
    go func() { fmt.Println(it) }()
}

// CERTO (funciona em qualquer versão)
for _, it := range items {
    go func(it string) { fmt.Println(it) }(it)
}
```

> Em Go 1.22+ a variável de loop passou a ser por iteração e o primeiro caso
> funciona. **Diga isso** — mostra que você acompanha a linguagem. Mas escreva
> a forma explícita, que é segura em qualquer versão.

```go
// ERRADO — wg.Wait() antes de drenar o canal = deadlock
wg.Wait()
for r := range results { ... }

// CERTO
go func() { wg.Wait(); close(results) }()
for r := range results { ... }
```

## Se pedirem errgroup

```go
import "golang.org/x/sync/errgroup"

g, ctx := errgroup.WithContext(ctx)
for _, it := range items {
    it := it
    g.Go(func() error {
        return processar(ctx, it)     // 1º erro cancela o ctx dos demais
    })
}
if err := g.Wait(); err != nil {
    return err
}
```

---

# COMO TREINAR (o essencial nas próximas 48h)

## Regra: apague e reescreva

Não adianta *ler* os esqueletos. O treino é:

1. Leia o esqueleto uma vez
2. **Feche o arquivo**
3. Escreva do zero num arquivo vazio
4. Rode. Se não compilar/rodar, conserte **sem olhar**
5. Só então compare

Repita até sair em ~20 min sem consulta. **Três repetições valem mais que
três horas de leitura.**

## Ambiente pronto

```bash
# Python (Windows)
cd coding\python
python meu_teste.py

# Go (no WSL — Go 1.22 já instalado)
wsl -d Ubuntu-24.04
cd /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/coding/go
go run meu_teste.go
```

> **Instale Go no Windows antes da entrevista** se for escolher Go — depender do
> WSL ao vivo adiciona uma camada de risco. `winget install GoLang.Go`

## Escolha a linguagem AGORA

Não treine as duas. Com 48h, meia dose de cada é pior que dose cheia de uma.

| Escolha | Se |
|---|---|
| **Python** | Você tem mais fluência; o exercício do roteiro (restart_count) é literalmente Python |
| **Go** | Você já escreveu goroutines antes; a vaga valoriza mais |

Se estiver em dúvida: **Python**. O risco de travar em sintaxe é muito menor, e
o roteiro cita o exercício de pods em Python explicitamente.

## Se travar na entrevista

- **Escreva o esqueleto primeiro, preencha depois.** Assinatura da função, `pass`
  no corpo, e vá enchendo.
- **Fale antes de escrever.** *"Vou percorrer os items, somar os restartCount de
  cada container e filtrar pelo limite."* O entrevistador corrige o rumo antes de
  você perder 5 minutos.
- **Nunca fique em silêncio.** Pensar alto é metade da avaliação.
- **Não invente API.** Se não lembra se é `restartCount` ou `restart_count`,
  pergunte ou diga *"vou assumir camelCase, que é o padrão da API"*.
