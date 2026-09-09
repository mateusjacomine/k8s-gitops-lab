// EXERCICIO 3 — 25 minutos, sem consultar nada.
//
// Implemente runPool: processa items com N workers concorrentes, respeitando
// o context (timeout/cancelamento) e devolvendo TODOS os resultados.
//
// Rode:  go run .          (os testes em pool_test.go validam)
//        go test -race .   (obrigatorio passar sem data race)
package main

import (
	"context"
	"fmt"
	"time"
)

// Result carrega o valor OU o erro — nunca os dois.
type Result struct {
	Item string
	Err  error
}

// process simula I/O (chamada ao API server, HTTP...).
// NAO altere: ela ja respeita o context corretamente.
func process(ctx context.Context, item string) (string, error) {
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case <-time.After(80 * time.Millisecond):
		if item == "falha" {
			return "", fmt.Errorf("item %q invalido", item)
		}
		return item + "-ok", nil
	}
}

// runPool processa items com `workers` goroutines concorrentes.
// Deve devolver um Result para CADA item de entrada.
func runPool(ctx context.Context, items []string, workers int) []Result {
	// ==================== ESCREVA AQUI ====================
	//
	// Lembre-se dos 4 pontos:
	//   1. close(jobs) no produtor      -> senao os workers travam no range
	//   2. defer wg.Done() no worker
	//   3. close(results) so apos wg.Wait(), em goroutine separada
	//   4. select com ctx.Done() no produtor
	//
	panic("implemente runPool()")
	// ======================================================
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	items := []string{"a", "b", "c", "falha", "e"}
	res := runPool(ctx, items, 3)

	var ok, fail int
	for _, r := range res {
		if r.Err != nil {
			fail++
			fmt.Println("erro:", r.Err)
			continue
		}
		ok++
		fmt.Println(r.Item)
	}
	fmt.Printf("total=%d ok=%d falhas=%d\n", len(res), ok, fail)
	fmt.Println("\nrode `go test -race .` para validar")
}
