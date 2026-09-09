# Guia de Treino — Como simular e diagnosticar cada problema

> **Regra de ouro:** aplique o cenário, **diagnostique sozinho** e só depois
> compare com a resposta. Ler a resposta antes não treina nada.

## Onde rodar

O `break.sh` roda no **WSL** (precisa de SSH para os cenários de node):

```bash
wsl -d Ubuntu-24.04
cd /mnt/c/Users/Mateus/PycharmProjects/Projeto_Entrevista/labs
bash break.sh              # lista os cenários
bash break.sh status       # visão geral do cluster
```

Comandos `kubectl` você pode rodar no PowerShell também.

---

## Cenário 1 — Pods quebrados

```bash
bash break.sh pods
kgpw -n lab-pods        # deixe rodando: veja RESTARTS subir ao vivo
```

**Diagnostique antes de ler:** por que cada um dos 6 pods está falhando?

<details>
<summary>Respostas</summary>

| Pod | Sintoma | Causa | Comando-chave |
|---|---|---|---|
| `crashloop` | CrashLoopBackOff | app sai com exit 1 | `k logs crashloop -n lab-pods --previous` |
| `oomkilled` | CrashLoopBackOff | limit 32Mi, usa 200Mi | `kdp oomkilled -n lab-pods` → **Exit Code 137** |
| `pending-recursos` | Pending | pede 64Gi de RAM | `kdp` → Events: FailedScheduling |
| `probe-errada` | Running **0/1** | readiness na porta 8080, nginx na 80 | `k get endpoints -n lab-pods` → vazio |
| `image-inexistente` | ImagePullBackOff | tag inexistente | `kdp` → Failed to pull image |
| `liveness-agressiva` | RESTARTS subindo | probe mata antes do warm-up de 30s | `kdp` → Liveness probe failed |

**Sequência que você deve verbalizar:**
```bash
kgp -n lab-pods                          # 1. qual a FASE?
kdp <pod> -n lab-pods                    # 2. o que dizem os EVENTOS?
k logs <pod> -n lab-pods --previous      # 3. o que o processo disse?
```
O `--previous` é obrigatório em CrashLoop: o container atual pode nem existir.
</details>

```bash
bash break.sh fix-pods
```

---

## Cenário 2 — Node NotReady

```bash
bash break.sh kubelet-down
kubectl get nodes -w         # ~40s até NotReady
```

**Pergunta-chave:** os pods que estavam em `k8s-w1` pararam de rodar?

<details>
<summary>Resposta</summary>

**Não.** O containerd continua vivo — os containers seguem servindo tráfego. O
que parou foi o *reporte de estado* ao API server.

`node-monitor-grace-period` = 40s até `NotReady`; após ~5min o controller começa
a despejar os pods.

```bash
kubectl describe node k8s-w1 | grep -A6 Conditions
kubectl -n kube-node-lease get lease k8s-w1 -o yaml | grep renewTime  # parou

# No node:
ssh vagrant@192.168.172.131
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50 --no-pager
```
</details>

```bash
bash break.sh fix-kubelet-down
```

---

## Cenário 3 — DNS quebrado

```bash
bash break.sh coredns-down
kubectl run t --rm -it --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
```

<details>
<summary>Caminho de diagnóstico (a ordem importa)</summary>

O roteiro pede exatamente esta cadeia: **DNS → Endpoints → kube-proxy/CNI → NetworkPolicy**

```bash
# 1. CoreDNS está rodando?
kgp -n kube-system -l k8s-app=kube-dns          # 0 réplicas!

# 2. O Service de DNS tem endpoints?
kubectl -n kube-system get endpoints kube-dns   # vazio

# 3. Teste de dentro de um pod
kubectl run t --rm -it --image=nicolaka/netshoot --restart=Never -- \
  sh -c 'cat /etc/resolv.conf; nslookup kubernetes.default'
```
`/etc/resolv.conf` aponta para o ClusterIP do kube-dns (10.96.0.10). Sem
endpoints atrás dele, toda resolução falha — e a aplicação reporta
"connection refused" que **parece** erro de rede, mas é DNS.
</details>

```bash
bash break.sh fix-coredns-down
```

---

## Cenário 4 — Service sem endpoints

```bash
kubectl apply -f 03-network/network-scenarios.yaml
kubectl -n backend get endpoints
```

<details>
<summary>A distinção que separa sênior de pleno</summary>

```
api                10.244.x.x:80,10.244.x.x:80     <- correto
api-porta-errada   10.244.x.x:8080,...             <- TEM endpoints, porta errada
api-quebrado       <none>                          <- selector não casa
```

| Sintoma | Causa | Como confirmar |
|---|---|---|
| `ENDPOINTS <none>` | selector do Service ≠ labels do pod | `k get pods --show-labels` vs `k get svc -o yaml` |
| Endpoints existem, conexão recusada | `targetPort` errado | comparar com `containerPort` do pod |
| Endpoints existem, pod 0/1 | readiness falhando | pod não-Ready **sai** dos Endpoints |

Teste:
```bash
kubectl -n frontend exec client -- curl -m3 http://api.backend.svc.cluster.local
kubectl -n frontend exec client -- curl -m3 http://api-quebrado.backend.svc.cluster.local
```
</details>

---

## Cenário 5 — NetworkPolicy

```bash
bash 03-network/test-netpol.sh       # roteiro completo: baseline → deny → allow
```

<details>
<summary>O que a sequência prova</summary>

| Passo | frontend → api | backend interno → api |
|---|---|---|
| Sem policy | 200 | 200 |
| `default-deny-ingress` | bloqueado | **bloqueado** |
| `allow-frontend-to-api` | 200 | **ainda bloqueado** |

O terceiro passo é o ponto de ouro: o pod no *mesmo namespace* segue bloqueado,
provando que `podSelector: {}` alcança tudo e que a liberação foi estritamente
por `namespaceSelector`.

**Conceito para verbalizar:** NetworkPolicy é *deny-by-default apenas depois que
existe alguma policy* selecionando o pod. Sem nenhuma policy, tudo é permitido.
Policies são **aditivas** — não existe "deny" explícito, apenas ausência de allow.
</details>

```bash
kubectl -n backend delete networkpolicy --all
```

---

## Cenário 6 — DiskPressure

```bash
bash break.sh disk-pressure
kubectl describe node k8s-w1 | grep -A6 Conditions
```

<details>
<summary>O que observar</summary>

```
DiskPressure   True    KubeletHasDiskPressure
```
Thresholds padrão: `nodefs.available<10%`, `imagefs.available<15%`.

Efeitos em cadeia: o kubelet faz GC de imagens → despeja pods (BestEffort
primeiro) → marca o node como não-agendável para novos pods.

```bash
kubectl get events -A --sort-by=.metadata.creationTimestamp | grep -i evict
```
</details>

```bash
bash break.sh fix-disk-pressure
```

---

## Cenário 7 — PDB bloqueando drain

```bash
kubectl apply -f 02-nodes/pdb-drain-scenario.yaml
kubectl -n lab-nodes get pdb          # ALLOWED DISRUPTIONS: 0
kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data --timeout=60s
```

<details>
<summary>Por que trava e como resolver</summary>

O drain falha com *"Cannot evict pod as it would violate the pod's disruption
budget"*. Causa: `minAvailable: 2` com apenas 2 réplicas → zero disrupções
permitidas.

Três correções, com trade-offs diferentes:
- `replicas: 3` — mantém a garantia, custa recurso
- `minAvailable: 1` — aceita rodar degradado durante a manutenção
- `maxUnavailable: 1` — escala junto com o número de réplicas (**melhor prática**)

**PDB só protege contra disrupção voluntária** (drain, upgrade). Node que morre
sozinho ignora PDB completamente.
</details>

```bash
kubectl uncordon k8s-w1
kubectl delete -f 02-nodes/pdb-drain-scenario.yaml
```

---

## Cenário 8 — CPU throttling

```bash
kubectl apply -f 04-observability/throttling-demo.yaml
sleep 30
kubectl exec throttled   -- cat /sys/fs/cgroup/cpu.stat
kubectl exec sem-limite  -- cat /sys/fs/cgroup/cpu.stat
```

<details>
<summary>A leitura das métricas</summary>

Em `throttled`: `nr_throttled` e `throttled_usec` crescem sem parar.
Em `sem-limite`: `nr_throttled` fica em 0.

**Mecanismo:** o CFS divide o tempo em períodos de 100ms. Limit de `200m` = 20ms
por período. O processo que quer mais é **congelado** até o próximo período.

**A frase que fecha:** *"o container não tem erro, não reiniciou e o log está
limpo — mas está congelado a maior parte do tempo. Só a métrica
`container_cpu_cfs_throttled_seconds_total` mostra isso. É por isso que métricas
e logs não se substituem."*

Compare também as classes de QoS:
```bash
kubectl get pod qos-guaranteed qos-besteffort -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.qosClass}{"\n"}{end}'
```
</details>

```bash
kubectl delete -f 04-observability/throttling-demo.yaml
```

---

## Restaurar tudo

```bash
bash break.sh fix              # desfaz todos os cenários
```

Se algo ficar inconsistente, volte ao snapshot:

```powershell
cd infra\scripts
.\snapshot.ps1 restore cluster-limpo
```

---

## Treino cronometrado (faça na véspera)

1. Peça para alguém rodar **um** cenário sem te dizer qual
2. Cronometre **10 minutos** para descobrir e corrigir
3. **Fale em voz alta** o tempo todo — é isso que está sendo avaliado

Ordem que sempre funciona:
```
kgn                  → algum node fora?
kbad                 → quais pods não estão Running?
kev | tail -20       → o que aconteceu recentemente?
kdp <pod>            → eventos daquele pod
k logs <pod> --previous
```
