# Instala kubectl no Windows e traz o kubeconfig do cluster.
# Assim voce usa o terminal do Windows/PyCharm na entrevista, sem entrar no WSL.
$ErrorActionPreference = 'Stop'

$kubeDir = "$env:USERPROFILE\.kube"
$binDir  = "$env:USERPROFILE\bin"
New-Item -ItemType Directory -Force $kubeDir, $binDir | Out-Null

# --- kubectl ---
$kubectl = "$binDir\kubectl.exe"
if (-not (Test-Path $kubectl)) {
    Write-Host "==> Baixando kubectl..."
    $ver = (Invoke-WebRequest -Uri 'https://dl.k8s.io/release/stable.txt' -UseBasicParsing).Content.Trim()
    Invoke-WebRequest -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" `
        -OutFile $kubectl -UseBasicParsing
    Write-Host "    kubectl $ver -> $kubectl"
} else {
    Write-Host "==> kubectl ja existe em $kubectl"
}

# --- kubeconfig (vem do WSL, que ja o obteve do control-plane) ---
Write-Host "==> Copiando kubeconfig do WSL"
$cfg = wsl -d Ubuntu-24.04 -u root -- cat /root/.kube/config
if (-not $cfg) { throw "Nao consegui ler o kubeconfig do WSL. Rode 04-join-workers.sh antes." }
[System.IO.File]::WriteAllLines("$kubeDir\config", $cfg)
Write-Host "    -> $kubeDir\config"

# --- PATH do usuario ---
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$binDir", 'User')
    Write-Host "==> $binDir adicionado ao PATH (reabra o terminal)"
}
$env:Path += ";$binDir"

Write-Host "`n==> Teste:"
& $kubectl get nodes -o wide
