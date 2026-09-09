# Adiciona reservas DHCP por MAC no VMnet8 (NAT), fora da faixa dinamica.
# EXECUTAR COMO ADMINISTRADOR (mexe em C:\ProgramData e reinicia servico).
#
# Por que: o kubeadm amarra certificados e o kubelet ao IP do no. Com DHCP puro,
# um IP que muda apos reboot quebra o cluster. A reserva mantem DHCP (como pedido)
# porem com IP sempre igual.
$ErrorActionPreference = 'Stop'

$conf = 'C:\ProgramData\VMware\vmnetdhcp.conf'
$marker = '# === K8S LAB RESERVATIONS ==='

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Execute este script em um PowerShell COMO ADMINISTRADOR."
}

Copy-Item $conf "$conf.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
$content = Get-Content $conf -Raw

if ($content -match [regex]::Escape($marker)) {
    Write-Host "Reservas ja aplicadas. Nada a fazer."
} else {
    $block = @"

$marker
host k8s-cp1 {
    hardware ethernet 00:50:56:2A:10:11;
    fixed-address 192.168.172.11;
}
host k8s-w1 {
    hardware ethernet 00:50:56:2A:10:21;
    fixed-address 192.168.172.21;
}
host k8s-w2 {
    hardware ethernet 00:50:56:2A:10:22;
    fixed-address 192.168.172.22;
}
# === FIM K8S LAB ===
"@
    Add-Content -Path $conf -Value $block -Encoding ASCII
    Write-Host "Reservas adicionadas em $conf"
}

Write-Host "==> Reiniciando VMnetDHCP..."
Restart-Service VMnetDHCP -Force
Get-Service VMnetDHCP | Select-Object Name, Status | Format-Table -AutoSize
Write-Host "OK. cp1=192.168.172.11  w1=.21  w2=.22"
