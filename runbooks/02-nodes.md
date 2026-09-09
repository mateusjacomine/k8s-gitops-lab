# Runbook — Node NotReady e Manutenção

## Como um node fica NotReady

O **kubelet** envia heartbeat ao API server a cada 10s (`--node-status-update-frequency`).
Se o control-plane não recebe por `node-monitor-grace-period` (**40s** por padrão),
marca o node `NotReady`. Após ~5min, o controller começa a despejar os pods.

**Ponto importante para a entrevista:** `NotReady` significa "o kubelet parou de
responder" — a máquina pode estar perfeitamente viva. Por isso o primeiro passo é
distinguir *nó morto* de *kubelet morto*.

## Fluxo de diagnóstico

```bash
# 1) O que o cluster enxerga
kubectl get nodes -o wide
kubectl describe node k8s-w1 | sed -n '/Conditions:/,/Addresses:/p'

# 2) A maquina responde?
ping -c2 192.168.172.131
ssh vagrant@192.168.172.131

# 3) No node: o kubelet esta vivo?
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100 --no-pager
sudo journalctl -u kubelet --since "10 min ago" -p err

# 4) O runtime esta vivo? (kubelet depende dele)
sudo systemctl status containerd
sudo crictl info
sudo crictl ps

# 5) Recursos da maquina
df -h /var/lib/containerd /var/log     # DiskPressure
free -m                                # MemoryPressure
uptime                                 # load
sudo dmesg -T | grep -i -E 'oom|killed process' | tail
```

## Node Conditions — o que cada uma significa

| Condition | `True` significa | Efeito |
|---|---|---|
| `Ready` | kubelet saudável | `False`/`Unknown` → não agenda, depois despeja |
| `MemoryPressure` | memória baixa no node | Despeja pods BestEffort primeiro |
| `DiskPressure` | disco baixo (imagefs/nodefs) | Garbage collection de imagens; despeja pods |
| `PIDPressure` | PIDs esgotando | Impede novos processos |
| `NetworkUnavailable` | rota de rede não configurada | CNI não inicializou |

Thresholds padrão do kubelet: `memory.available<100Mi`,
`nodefs.available<10%`, `imagefs.available<15%`.

## Cenário prático — parar o kubelet

```bash
# Quebrar (em k8s-w1):
sudo systemctl stop kubelet

# Observar (no cp1):  ~40s ate NotReady
kubectl get nodes -w

# Diagnosticar:
kubectl describe node k8s-w1 | grep -A6 Conditions
# Lease para de ser renovado:
kubectl -n kube-node-lease get lease k8s-w1 -o yaml | grep renewTime

# Consertar:
sudo systemctl start kubelet
```

**Detalhe que impressiona:** os pods do node continuam **rodando** enquanto o
kubelet está parado — o containerd não morreu. O que para é o *reporte de estado*
e a capacidade de reagir a mudanças.

## Cenário — DiskPressure

```bash
# Quebrar: encher o disco
sudo fallocate -l 14G /var/lib/containerd/enchendo.img
df -h /var

# Observar
kubectl describe node k8s-w1 | grep -A6 Conditions   # DiskPressure=True
kubectl get events -A --sort-by='.metadata.creationTimestamp' | grep -i evict

# Consertar
sudo rm /var/lib/containerd/enchendo.img
sudo crictl rmi --prune          # limpa imagens nao usadas
```

## Cordon / Drain — a sequência correta em produção

```bash
# 1) Impede NOVOS pods (os atuais ficam)
kubectl cordon k8s-w1

# 2) Ensaio: ver o que sairia, sem executar
kubectl drain k8s-w1 --ignore-daemonsets --dry-run=client

# 3) Drenar de verdade
kubectl drain k8s-w1 \
  --ignore-daemonsets \        # DaemonSets nao sao despejaveis
  --delete-emptydir-data \     # so se souber que os dados sao descartaveis
  --grace-period=60 \
  --timeout=5m

# 4) Manutencao... depois:
kubectl uncordon k8s-w1
```

**Por que `--ignore-daemonsets`?** DaemonSets são recriados imediatamente no
mesmo node pelo controller; sem a flag, o drain trava.

### PodDisruptionBudget — a resposta que separa sênior de pleno

Um PDB define **quantos pods podem estar indisponíveis simultaneamente** durante
uma *disrupção voluntária* (drain, upgrade). O drain **respeita** o PDB e
**bloqueia** se violá-lo.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-pdb
spec:
  minAvailable: 2        # ou maxUnavailable: 1
  selector:
    matchLabels:
      app: api
```

Se você tem 2 réplicas e `minAvailable: 2`, o drain **trava para sempre** — é a
pegadinha clássica. Diagnóstico:

```bash
kubectl get pdb -A
kubectl describe pdb api-pdb        # ALLOWED DISRUPTIONS: 0  <<< o problema
```

**PDB não protege contra disrupção involuntária** (node que morre, OOM do kernel).
Só contra as voluntárias.

## Drenar durante o pico — o que responder

O roteiro cita "antes de drenar workloads durante horário de pico". A resposta
esperada:

1. **Não drene primeiro** — verifique se dá para esperar a janela de manutenção.
2. Se for urgente: confirme **capacidade sobrando** nos outros nodes
   (`kubectl describe nodes | grep -A5 'Allocated resources'`). Drenar um node
   sem espaço nos demais deixa os pods `Pending`.
3. Confira **PDBs** — `ALLOWED DISRUPTIONS: 0` trava o processo.
4. `cordon` primeiro, deixe o tráfego drenar naturalmente, depois `drain`.
5. Drene **um node por vez**, validando entre cada um.
6. Tenha `terminationGracePeriodSeconds` adequado e `preStop` hooks para
   conexões em andamento.

## Upgrade de cluster sem downtime

```bash
# 1) ANTES: checar APIs depreciadas que serao removidas
kubectl api-resources
# ferramentas: kubent (kube-no-trouble), pluto

# 2) Control-plane primeiro, um por vez
sudo dnf install -y kubeadm-1.32.x --disableexcludes=kubernetes
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.32.x

# 3) Depois kubelet/kubectl DO control-plane
kubectl drain k8s-cp1 --ignore-daemonsets
sudo dnf install -y kubelet-1.32.x kubectl-1.32.x --disableexcludes=kubernetes
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon k8s-cp1

# 4) Workers, UM POR VEZ
kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data
sudo kubeadm upgrade node
sudo dnf install -y kubelet-1.32.x --disableexcludes=kubernetes
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon k8s-w1
```

**Regras de ouro:**
- **Skew policy**: kubelet pode estar até 3 versões *menores* que o API server,
  nunca maior. Nunca pule uma minor version (1.30 → 1.32 é proibido).
- **etcd backup antes de tudo**:
  `sudo ETCDCTL_API=3 etcdctl snapshot save /backup/etcd.db --endpoints=... --cacert=... --cert=... --key=...`
- **Rollback**: control-plane volta pelo snapshot do etcd; worker volta
  reinstalando o pacote anterior do kubelet. Por isso se faz um node por vez.
