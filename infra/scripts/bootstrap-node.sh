#!/usr/bin/env bash
# Prepara um nó Rocky 9 para o Kubernetes (roda em cp1 e nos workers).
# Idempotente: pode rodar de novo sem quebrar nada.
set -euo pipefail

K8S_MINOR="${K8S_MINOR:-v1.31}"

echo "==> [1/7] Desabilitando swap"
swapoff -a
# Comenta swap no fstab (instalacao manual costuma criar LV de swap)
sed -i.bak '/\sswap\s/s/^\([^#]\)/#\1/' /etc/fstab
# Desabilita units de swap do systemd (LVM ou zram)
for u in $(systemctl list-units --type swap --no-legend --plain 2>/dev/null | awk '{print $1}'); do
  systemctl mask "$u" 2>/dev/null || true
done
systemctl disable --now dev-zram0.swap 2>/dev/null || true
rm -f /etc/systemd/zram-generator.conf 2>/dev/null || true
echo "    swap restante: $(swapon --show --noheadings 2>/dev/null | wc -l) entrada(s)"

echo "==> [2/7] Modulos de kernel (overlay, br_netfilter)"
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "==> [3/7] Sysctls de rede"
cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "==> [4/7] SELinux em permissive"
setenforce 0 2>/dev/null || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true

echo "==> [5/7] Instalando containerd"
if ! command -v containerd >/dev/null; then
  dnf install -y -q dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y -q containerd.io
fi

containerd config default >/etc/containerd/config.toml
# CRITICO: o kubelet usa cgroup driver systemd; containerd precisa combinar,
# senao os pods entram em CrashLoop por conflito de cgroups.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd
systemctl restart containerd

echo "==> [6/7] Repositorio e pacotes do Kubernetes ($K8S_MINOR)"
cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

dnf install -y -q --disableexcludes=kubernetes kubelet kubeadm kubectl
systemctl enable --now kubelet

echo "==> [7/7] crictl apontando para o containerd"
cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# firewalld ja veio desabilitado pelo kickstart; garante
systemctl disable --now firewalld 2>/dev/null || true

echo "==> Bootstrap concluido em $(hostname)"
kubeadm version -o short
containerd --version
