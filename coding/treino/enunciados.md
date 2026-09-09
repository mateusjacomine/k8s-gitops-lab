# Exercícios de Treino — escreva do zero, sem consultar

Cronometre. Feche os outros arquivos. Se travar por mais de 2 minutos num ponto,
anote qual foi e siga — depois revise **só aquele ponto**.

---

## Exercício 1 — Python · 20 min

> Você recebe um JSON de `kubectl get pods -A -o json`. Escreva um script que
> imprima os pods com mais de 5 restarts, do pior para o melhor.

**Critérios (o entrevistador está olhando isto):**
- [ ] Trata `items` ausente ou `null`
- [ ] Trata pod sem `containerStatuses` (acontece em Pending)
- [ ] Soma restarts de **todos** os containers do pod
- [ ] Ordena decrescente
- [ ] Não quebra com JSON vazio

**Teste com:** `coding/python/sample_pods.json`

**Resultado esperado:** 4 pods (12, 9, 8, 7 restarts).

---

## Exercício 2 — Python · +10 min

> Acrescente um filtro: só pods criados nas últimas 24 horas.

- [ ] Converte `creationTimestamp` (formato `2026-09-07T18:47:18Z`)
- [ ] Decide o que fazer quando o timestamp falta — **e explica a decisão**
- [ ] Usa datetime *aware* (com timezone), nunca naive

**Resultado esperado:** 3 pods (o de 58h sai; o sem timestamp também).

---

## Exercício 3 — Go · 25 min

> Processe uma lista de N itens com W workers concorrentes. Colete os resultados,
> conte sucessos e falhas, e respeite um timeout global.

**Critérios:**
- [ ] `sync.WaitGroup` com `defer wg.Done()`
- [ ] `close(jobs)` no produtor
- [ ] `close(results)` só depois de `wg.Wait()`, em goroutine separada
- [ ] `context.WithTimeout` e `select` com `ctx.Done()` no worker
- [ ] Compila com `go vet` limpo e roda com `-race` sem warning

**Valide:**
```bash
go vet ./... && go run -race .
```

---

## Exercício 4 — Go · +10 min

> Faça o timeout de 200ms e mostre que o programa termina em ~200ms,
> não esperando todos os workers.

Se demorar mais que isso, seu `ctx.Done()` não está no lugar certo.

---

## Exercício 5 — misto · 15 min

> Sem escrever código: explique em voz alta, cronometrado.

1. Diferença entre `requests` e `limits`, e por que memória mata mas CPU só atrasa
2. Por que `kubectl logs --previous` em CrashLoopBackOff
3. Em Python: threads vs asyncio vs multiprocessing — qual para chamar 50 endpoints
4. Em Go: por que `close(results)` precisa da goroutine com `wg.Wait()`

---

## Registro de treino

Preencha — mostra onde você realmente está.

| Exercício | 1ª tentativa | 2ª | 3ª | Onde travei |
|---|---|---|---|---|
| 1 (Python básico) | | | | |
| 2 (Python + tempo) | | | | |
| 3 (Go pool) | | | | |
| 4 (Go timeout) | | | | |

**Meta:** exercício 1 em 15 min e exercício 3 em 20 min, sem consultar nada.
