#!/usr/bin/env bash
# Valida SSH, sudo e recursos das 3 VMs antes do bootstrap.
set -u
PASS="${LAB_PASS:-vagrant}"
USER_="${LAB_USER:-vagrant}"
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR"

for entry in "cp1:192.168.172.130" "wk1:192.168.172.131" "wk2:192.168.172.132"; do
  name="${entry%%:*}"; ip="${entry##*:}"
  echo "=============== $name ($ip) ==============="
  if ! timeout 5 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null; then
    echo "  SSH: porta 22 FECHADA/inacessivel"
    continue
  fi
  out=$(sshpass -p "$PASS" ssh $SSHOPTS "$USER_@$ip" '
    echo "  hostname: $(hostname)"
    echo "  os:       $(source /etc/os-release; echo $PRETTY_NAME)"
    echo "  kernel:   $(uname -r)"
    echo "  cpus:     $(nproc)"
    echo "  mem:      $(free -m | awk "/^Mem:/{print \$2\" MB\"}")"
    echo "  disco /:  $(df -h / | awk "NR==2{print \$4\" livre de \"\$2}")"
    echo "  ip:       $(hostname -I)"
    echo "  swap:     $(swapon --show --noheadings 2>/dev/null | wc -l) entrada(s)"
    echo "  selinux:  $(getenforce 2>/dev/null || echo n/a)"
    echo "  firewalld:$(systemctl is-active firewalld 2>/dev/null)"
    echo "  sudo:     $(sudo -n true 2>/dev/null && echo "NOPASSWD ok" || echo "exige senha")"
  ' 2>&1)
  if [ -n "$out" ]; then echo "$out"; else echo "  FALHA no login SSH"; fi
done
