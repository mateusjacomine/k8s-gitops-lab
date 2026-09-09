# Exercícios de Coding — Go e Python

Ambos resolvem o mesmo problema de fundo: **processar dados do Kubernetes com
tratamento de erro e casos de borda**. Escolha a linguagem na hora da entrevista.

---

## Python — `pod_analyzer.py`

Filtra pods por `restartCount` e janela temporal. É o exercício literal citado no
roteiro da vaga ("filter pods based on restart_count > 5 or timestamp conditions").

```bash
python pod_analyzer.py sample_pods.json --min-restarts 5
python pod_analyzer.py sample_pods.json --min-restarts 5 --since-hours 24
kubectl get pods -A -o json | python pod_analyzer.py - --min-restarts 5
```

### Casos de borda tratados (aponte cada um em voz alta)

| Caso | Onde é tratado |
|---|---|
| `items` ausente ou `null` | `payload.get("items") or []` |
| Pod sem `containerStatuses` (Pending) | `status.get("containerStatuses") or []` |
| Pod sem `metadata.name` | descartado em `analyze_pod` |
| Timestamp com `Z` vs `+00:00` | `parse_k8s_timestamp` normaliza |
| Timestamp ausente | `age_hours = None`, excluído da janela **por decisão explícita** |
| Init containers com restart | somados junto aos containers normais |
| Entrada é um Pod único, não PodList | `iter_pods` aceita ambos |
| JSON vazio / inválido | erro claro, exit code 2 |

### Perguntas prováveis

**"E se fossem 10.000 pods?"**
O parsing é O(n) e streaming-friendly. O gargalo seria a chamada de rede, não o
processamento. Para múltiplos clusters eu paralelizaria as *chamadas* com
`asyncio` ou `ThreadPoolExecutor`.

**"asyncio vs threading vs multiprocessing?"**

| Ferramenta | Quando | Por quê |
|---|---|---|
| `asyncio` | Muitas chamadas de rede concorrentes | Sem overhead de thread; ideal para I/O do API server |
| `threading` | I/O moderado, libs bloqueantes | O GIL é liberado durante I/O |
| `multiprocessing` | Processamento CPU-bound | Único jeito de escapar do GIL de verdade |

Parsear JSON de pods é **I/O-bound** (esperar o API server), então `asyncio`
ou threads. `multiprocessing` só se fosse fazer cálculo pesado sobre os dados.

---

## Go — `main.go`

Worker pool concorrente com goroutines, channels, `sync.WaitGroup` e
cancelamento por `context` — exatamente o que o roteiro pede.

```bash
cd coding/go
go mod init podcheck   # primeira vez
go run . -workers 4 -timeout 5s
go run . -workers 2 -timeout 200ms    # força cancelamento
go run -race .                        # prova ausência de data race
```

### Pontos técnicos para explicar

**Por que `close(jobs)`?** Sem isso, o `for range jobs` dos workers nunca termina
e o programa trava (deadlock).

**Por que fechar `results` numa goroutine separada?**
```go
go func() { wg.Wait(); close(results) }()
```
`wg.Wait()` bloqueia. Se fosse chamado na main antes do `range results`, os
workers ficariam presos escrevendo num canal que ninguém lê — deadlock clássico.

**Por que o produtor observa `ctx.Done()`?** Para parar de enfileirar trabalho
após um cancelamento, em vez de bloquear em `jobs <- t` para sempre.

**Buffer em `results`:** `make(chan Result, len(targets))` garante que nenhum
worker bloqueie ao entregar resultado.

**Ordenação no fim:** concorrência devolve resultados fora de ordem; ordenar
torna a saída determinística e testável.

### Perguntas prováveis

**"Como limitaria a taxa de requisições?"** `time.Ticker` no produtor, ou
`golang.org/x/time/rate` com um `Limiter`.

**"Como propagaria o primeiro erro e cancelaria o resto?"**
`errgroup.WithContext` — o primeiro erro cancela o context de todos os demais.

**"Diferença entre `context.WithTimeout` e `WithDeadline`?"** Timeout é relativo
(daqui a 5s), deadline é absoluto (às 14:30:00). Timeout é açúcar sintático
sobre deadline.

---

## Checklist antes da call

- [ ] `go run -race .` sem warnings
- [ ] Testar lista vazia nos dois programas
- [ ] Saber explicar por que 137 = OOMKilled (128 + SIGKILL 9)
- [ ] Verbalizar: "vou tratar o caso de campo ausente porque a API do K8s omite
      `containerStatuses` enquanto o pod está Pending"
