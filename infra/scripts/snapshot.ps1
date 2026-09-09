# Snapshots das 3 VMs. Permite quebrar o cluster e voltar em segundos.
#
#   .\snapshot.ps1 create cluster-limpo
#   .\snapshot.ps1 list
#   .\snapshot.ps1 restore cluster-limpo
#
# ATENCAO: restore reverte as 3 VMs juntas (o cluster precisa de estado
# consistente entre elas — restaurar so uma quebra os certificados/etcd).
param(
    [Parameter(Mandatory=$true)][ValidateSet('create','list','restore','delete')]
    [string]$Action,
    [string]$Name = 'cluster-limpo'
)
$ErrorActionPreference = 'Continue'
$VMRUN = 'C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe'

# Ajuste aqui se as VMs estiverem em outro caminho
$VMS = @{
    'k8s-cp1' = 'C:\k8s-lab\k8s-cp1\k8s-cp1.vmx'
    'k8s-w1'  = 'C:\k8s-lab\k8s-w1\k8s-w1.vmx'
    'k8s-w2'  = 'C:\k8s-lab\k8s-w2\k8s-w2.vmx'
}

# Descobre os .vmx reais caso estejam em outro lugar
$found = @{}
foreach ($n in $VMS.Keys) {
    if (Test-Path $VMS[$n]) { $found[$n] = $VMS[$n]; continue }
    $hit = Get-ChildItem -Path 'C:\','D:\','F:\' -Filter "$n.vmx" -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { $found[$n] = $hit.FullName }
}
if ($found.Count -eq 0) { throw "Nenhum .vmx encontrado. Edite `$VMS neste script." }

switch ($Action) {
    'create' {
        foreach ($n in $found.Keys) {
            Write-Host "==> snapshot '$Name' em $n"
            & $VMRUN -T ws snapshot $found[$n] $Name
        }
        Write-Host "`nPronto. Restaurar com: .\snapshot.ps1 restore $Name"
    }
    'list' {
        foreach ($n in $found.Keys) {
            Write-Host "=== $n ==="
            & $VMRUN -T ws listSnapshots $found[$n]
        }
    }
    'restore' {
        Write-Host "==> Restaurando as 3 VMs para '$Name'..."
        foreach ($n in $found.Keys) {
            & $VMRUN -T ws revertToSnapshot $found[$n] $Name
            & $VMRUN -T ws start $found[$n] nogui
            Write-Host "    $n revertida e ligada"
        }
        Write-Host "`nAguarde ~60s e valide: kubectl get nodes"
    }
    'delete' {
        foreach ($n in $found.Keys) { & $VMRUN -T ws deleteSnapshot $found[$n] $Name }
    }
}
