// Exercicio de concorrencia no formato pedido pela vaga:
// processar uma lista de itens em paralelo, tratar erros dos workers,
// respeitar cancelamento por context e agregar os resultados.
//
// Cenario: checar a saude de varios pods/endpoints simultaneamente.
//
// Rodar:  go run . -workers 4 -timeout 5s
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"sync"
	"time"
)

// Target e uma unidade de trabalho: um pod a inspecionar.
type Target struct {
	Namespace string
	Pod       string
	Restarts  int
}

// Result carrega o resultado OU o erro daquele alvo — nunca os dois.
type Result struct {
	Target  Target
	Healthy bool
	Latency time.Duration
	Err     error
}

// checkPod simula uma chamada de I/O (API server, endpoint HTTP).
// O ponto importante: ela respeita o context, entao um cancelamento
// interrompe o trabalho em vez de esperar o timer terminar.
func checkPod(ctx context.Context, t Target) (Result, error) {
	start := time.Now()

	// Latencia simulada entre 50ms e 550ms
	delay := time.Duration(50+rand.Intn(500)) * time.Millisecond

	select {
	case <-ctx.Done():
		// Cancelado/expirado: devolve o erro do context, nao um erro generico
		return Result{Target: t, Err: ctx.Err()}, ctx.Err()
	case <-time.After(delay):
	}

	// Falha simulada para exercitar o caminho de erro
	if t.Restarts > 10 {
		err := fmt.Errorf("pod %s/%s instavel: %d restarts", t.Namespace, t.Pod, t.Restarts)
		return Result{Target: t, Latency: time.Since(start), Err: err}, err
	}

	return Result{
		Target:  t,
		Healthy: t.Restarts == 0,
		Latency: time.Since(start),
	}, nil
}

// runPool e o padrao classico: N workers consumindo de um channel de entrada,
// escrevendo em um channel de saida, com WaitGroup para saber quando fechar.
func runPool(ctx context.Context, targets []Target, workers int) []Result {
	if workers < 1 {
		workers = 1
	}
	// Nao adianta ter mais worker que trabalho
	if workers > len(targets) {
		workers = len(targets)
	}

	jobs := make(chan Target)
	// Buffer do tamanho total: os workers nunca bloqueiam ao entregar resultado
	results := make(chan Result, len(targets))

	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for t := range jobs {
				res, _ := checkPod(ctx, t)
				results <- res
			}
		}(w)
	}

	// Produtor: fecha jobs ao terminar para que os workers saiam do range.
	// Tambem observa o ctx para nao continuar enfileirando apos cancelamento.
	go func() {
		defer close(jobs)
		for _, t := range targets {
			select {
			case jobs <- t:
			case <-ctx.Done():
				return
			}
		}
	}()

	// Fechar o canal de resultados so DEPOIS que todos os workers sairem.
	// Sem esta goroutine, o range abaixo trava para sempre.
	go func() {
		wg.Wait()
		close(results)
	}()

	collected := make([]Result, 0, len(targets))
	for r := range results {
		collected = append(collected, r)
	}
	return collected
}

// summarize agrega: separa sucessos de falhas e calcula latencia p95.
func summarize(results []Result) (healthy, unhealthy, failed int, p95 time.Duration) {
	latencies := make([]time.Duration, 0, len(results))
	for _, r := range results {
		switch {
		case r.Err != nil:
			failed++
		case r.Healthy:
			healthy++
			latencies = append(latencies, r.Latency)
		default:
			unhealthy++
			latencies = append(latencies, r.Latency)
		}
	}
	if len(latencies) == 0 {
		return
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	// indice p95 com clamp para nao estourar em amostras pequenas
	idx := int(float64(len(latencies)) * 0.95)
	if idx >= len(latencies) {
		idx = len(latencies) - 1
	}
	p95 = latencies[idx]
	return
}

func loadTargets(path string) ([]Target, error) {
	if path == "" {
		// Dataset embutido para demonstracao
		return []Target{
			{"production", "api-gateway-7d9f8b", 12},
			{"production", "worker-queue-5c8d9", 7},
			{"production", "web-frontend-a1b2c", 0},
			{"data", "cache-redis-0", 0},
			{"data", "postgres-0", 2},
			{"staging", "api-canary-9f8e7", 15},
			{"staging", "batch-job-x1y2", 0},
			{"kube-system", "coredns-abc12", 1},
		}, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var targets []Target
	if err := json.Unmarshal(raw, &targets); err != nil {
		return nil, fmt.Errorf("json invalido: %w", err)
	}
	return targets, nil
}

func main() {
	workers := flag.Int("workers", 4, "numero de workers concorrentes")
	timeout := flag.Duration("timeout", 5*time.Second, "timeout global")
	input := flag.String("input", "", "arquivo JSON com os alvos (opcional)")
	flag.Parse()

	targets, err := loadTargets(*input)
	if err != nil {
		fmt.Fprintf(os.Stderr, "erro ao carregar alvos: %v\n", err)
		os.Exit(2)
	}
	// Caso de borda que o entrevistador testa: lista vazia
	if len(targets) == 0 {
		fmt.Println("nenhum alvo para processar")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	start := time.Now()
	results := runPool(ctx, targets, *workers)
	elapsed := time.Since(start)

	// Ordena para saida deterministica (concorrencia devolve fora de ordem)
	sort.Slice(results, func(i, j int) bool {
		if results[i].Target.Namespace != results[j].Target.Namespace {
			return results[i].Target.Namespace < results[j].Target.Namespace
		}
		return results[i].Target.Pod < results[j].Target.Pod
	})

	fmt.Printf("%-14s %-24s %-10s %10s  %s\n", "NAMESPACE", "POD", "STATUS", "LATENCY", "ERRO")
	for _, r := range results {
		status := "healthy"
		errMsg := "-"
		switch {
		case r.Err != nil:
			status = "ERRO"
			errMsg = r.Err.Error()
			if errors.Is(r.Err, context.DeadlineExceeded) {
				errMsg = "timeout global excedido"
			}
		case !r.Healthy:
			status = "degraded"
		}
		fmt.Printf("%-14s %-24s %-10s %10s  %s\n",
			r.Target.Namespace, r.Target.Pod, status,
			r.Latency.Round(time.Millisecond), errMsg)
	}

	healthy, unhealthy, failed, p95 := summarize(results)
	fmt.Printf("\n%d alvos em %s com %d workers\n", len(results), elapsed.Round(time.Millisecond), *workers)
	fmt.Printf("healthy=%d degraded=%d falhas=%d p95=%s\n",
		healthy, unhealthy, failed, p95.Round(time.Millisecond))

	if failed > 0 {
		os.Exit(1)
	}
}
