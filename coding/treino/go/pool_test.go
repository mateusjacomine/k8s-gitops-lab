package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

// runPoolSeguro executa runPool com guarda de deadlock. O erro mais comum
// (esquecer close(jobs) ou close(results)) trava para sempre; sem esta guarda
// o teste so estoura o timeout global, sem dizer o que houve.
func runPoolSeguro(t *testing.T, ctx context.Context, items []string, workers int) []Result {
	t.Helper()
	done := make(chan []Result, 1)
	go func() {
		defer func() {
			if r := recover(); r != nil {
				t.Errorf("panic dentro de runPool: %v", r)
				done <- nil
			}
		}()
		done <- runPool(ctx, items, workers)
	}()

	select {
	case res := <-done:
		return res
	case <-time.After(10 * time.Second):
		t.Fatal("DEADLOCK: runPool nao retornou em 10s.\n" +
			"  Causas classicas:\n" +
			"   - falta close(jobs) no produtor -> workers presos no range\n" +
			"   - close(results) nao acontece    -> o range results nunca acaba\n" +
			"   - wg.Wait() chamado na main antes de drenar results")
		return nil
	}
}

// Todos os itens devem voltar, mesmo com workers < len(items).
func TestTodosOsItensVoltam(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	items := []string{"a", "b", "c", "d", "e", "f", "g"}
	res := runPoolSeguro(t, ctx, items, 3)

	if len(res) != len(items) {
		t.Fatalf("esperado %d resultados, veio %d (perdeu itens: close(jobs)/close(results) errado?)",
			len(items), len(res))
	}
}

// Erros de item individual nao podem derrubar o pool.
func TestErroNaoDerrubaOPool(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	res := runPoolSeguro(t, ctx, []string{"a", "falha", "c"}, 2)
	if len(res) != 3 {
		t.Fatalf("esperado 3 resultados, veio %d", len(res))
	}
	var comErro int
	for _, r := range res {
		if r.Err != nil {
			comErro++
		}
	}
	if comErro != 1 {
		t.Fatalf("esperado exatamente 1 erro, veio %d", comErro)
	}
}

// O ponto que separa quem entende context: com timeout curto o pool
// termina rapido, em vez de esperar todo o trabalho.
func TestRespeitaTimeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()

	items := make([]string, 40)
	for i := range items {
		items[i] = "x"
	}

	start := time.Now()
	res := runPoolSeguro(t, ctx, items, 2)
	elapsed := time.Since(start)

	if elapsed > 2*time.Second {
		t.Fatalf("demorou %v: o worker nao esta observando ctx.Done()", elapsed)
	}
	var deadline int
	for _, r := range res {
		if errors.Is(r.Err, context.DeadlineExceeded) {
			deadline++
		}
	}
	if deadline == 0 {
		t.Fatal("nenhum resultado com DeadlineExceeded: o ctx nao chega ao worker")
	}
}

// Concorrencia real: 8 itens de 80ms com 8 workers devem levar ~80ms,
// nao 640ms. Detecta pool que na verdade roda em serie.
func TestRodaEmParalelo(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	items := make([]string, 8)
	for i := range items {
		items[i] = "p"
	}

	start := time.Now()
	runPoolSeguro(t, ctx, items, 8)
	elapsed := time.Since(start)

	if elapsed > 400*time.Millisecond {
		t.Fatalf("levou %v para 8 itens de 80ms com 8 workers: nao esta paralelo", elapsed)
	}
}

// Lista vazia nao pode travar nem entrar em panic.
func TestListaVazia(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	done := make(chan []Result, 1)
	go func() { done <- runPool(ctx, nil, 3) }()

	select {
	case res := <-done:
		if len(res) != 0 {
			t.Fatalf("esperado 0 resultados, veio %d", len(res))
		}
	case <-time.After(2 * time.Second):
		t.Fatal("travou com lista vazia (deadlock)")
	}
}
