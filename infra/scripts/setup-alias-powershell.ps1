# Adiciona 'k' e atalhos de kubectl ao perfil do PowerShell.
# No PowerShell, Set-Alias nao repassa argumentos — por isso usamos funcoes.
$ErrorActionPreference = 'Stop'

$profilePath = $PROFILE.CurrentUserAllHosts
$dir = Split-Path $profilePath -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force $profilePath | Out-Null }

$marker = '# === k8s lab aliases ==='
$endTag = '# === fim k8s lab ==='

$content = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
if ($null -eq $content) { $content = '' }

# Remove bloco antigo para nao duplicar
if ($content -match [regex]::Escape($marker)) {
    $pattern = "(?s)" + [regex]::Escape($marker) + ".*?" + [regex]::Escape($endTag)
    $content = [regex]::Replace($content, $pattern, '')
}

$block = @'
# === k8s lab aliases ===
# Garante que ~\bin (onde kubectl.exe foi instalado) esteja no PATH da sessao
$__kbin = Join-Path $env:USERPROFILE 'bin'
if ((Test-Path $__kbin) -and ($env:Path -notlike "*$__kbin*")) {
    $env:Path = "$env:Path;$__kbin"
}

function k { kubectl @args }

function kg    { kubectl get @args }
function kd    { kubectl describe @args }
# describe pod: o uso dominante em troubleshooting (kd exige o tipo do recurso)
function kdp   { kubectl describe pod @args }
function kgp   { kubectl get pods @args }
function kgpa  { kubectl get pods -A @args }
# acompanha mudancas de estado ao vivo (Ctrl+C para sair)
function kgpw  { kubectl get pods -w @args }
function kgn   { kubectl get nodes -o wide @args }
function kl    { kubectl logs @args }
function klp   { kubectl logs --previous @args }
function kaf   { kubectl apply -f @args }
function kdel  { kubectl delete @args }
function kex   { kubectl exec -it @args }

# Eventos ordenados por tempo (caducam em ~1h)
function kev  { kubectl get events -A --sort-by=.metadata.creationTimestamp @args }
# Pods que nao estao Running.
# O PS 5.1 trata stderr de exe nativo como erro; "No resources found" vai para
# stderr, entao redirecionamos para stdout e mostramos como texto normal.
function kbad {
    $out = kubectl get pods -A --field-selector=status.phase!=Running @args 2>&1
    $out | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ } }
}
# Troca de namespace:  kns lab-pods
function kns  { param($ns='default') kubectl config set-context --current --namespace=$ns }

# Autocomplete do kubectl
if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    kubectl completion powershell | Out-String | Invoke-Expression
    # Faz 'k' herdar o completion de kubectl
    Register-ArgumentCompleter -CommandName k -ScriptBlock $__kubectlCompleterBlock
}
# === fim k8s lab ===
'@

$new = ($content.TrimEnd() + "`r`n`r`n" + $block + "`r`n").TrimStart()
[System.IO.File]::WriteAllText($profilePath, $new, [System.Text.UTF8Encoding]::new($false))

Write-Host "Perfil atualizado: $profilePath"
Write-Host "Recarregue com:  . `$PROFILE.CurrentUserAllHosts    (ou reabra o terminal)"
