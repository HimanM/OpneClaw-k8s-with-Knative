$ErrorActionPreference = "Stop"

$knativeVersion = "knative-v1.22.0"
$kourierVersion = "knative-v1.22.0"
$namespace = "agents"
$serviceName = "openclaw"
$domainSuffix = "localhost"
$routeHost = "$serviceName.$namespace.$domainSuffix"
$routeUrl = "http://$routeHost`:8080"
$serviceReadyTimeoutSeconds = 300

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not available on PATH."
    }
}

function Invoke-Kubectl {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )
    & kubectl @Args
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed: kubectl $($Args -join ' ')"
    }
}

function Ensure-KnativeServing {
    $knativeNs = (& kubectl get namespace knative-serving --ignore-not-found -o name).Trim()
    if (-not $knativeNs) {
        Write-Host "Installing Knative Serving $knativeVersion ..."
        Invoke-Kubectl apply -f "https://github.com/knative/serving/releases/download/$knativeVersion/serving-crds.yaml"
        Invoke-Kubectl apply -f "https://github.com/knative/serving/releases/download/$knativeVersion/serving-core.yaml"
    } else {
        Write-Host "Knative Serving namespace already present. Skipping core install."
    }

    Write-Host "Installing/refreshing Kourier $kourierVersion ..."
    Invoke-Kubectl apply -f "https://github.com/knative-extensions/net-kourier/releases/download/$kourierVersion/kourier.yaml"

    $networkPatch = @{
        data = @{
            "ingress-class" = "kourier.ingress.networking.knative.dev"
        }
    } | ConvertTo-Json -Compress
    $networkPatchEscaped = $networkPatch.Replace('"', '\"')
    Invoke-Kubectl patch configmap/config-network --namespace knative-serving --type merge --patch $networkPatchEscaped
}

function Wait-KnativeControlPlane {
    Write-Host "Waiting for Knative control plane readiness ..."
    Invoke-Kubectl wait deployment/activator --for=condition=Available -n knative-serving --timeout=300s
    Invoke-Kubectl wait deployment/autoscaler --for=condition=Available -n knative-serving --timeout=300s
    Invoke-Kubectl wait deployment/controller --for=condition=Available -n knative-serving --timeout=300s
    Invoke-Kubectl wait deployment/webhook --for=condition=Available -n knative-serving --timeout=300s
    Invoke-Kubectl wait deployment/net-kourier-controller --for=condition=Available -n knative-serving --timeout=300s
}

function Ensure-KnativeDomain {
    Write-Host "Configuring Knative domain suffix: $domainSuffix"
    $domainConfig = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-domain
  namespace: knative-serving
data:
  ${domainSuffix}: ""
"@

    $tmpFile = Join-Path $env:TEMP "knative-config-domain.yaml"
    Set-Content -Path $tmpFile -Value $domainConfig -Encoding UTF8

    $existing = (& kubectl get configmap config-domain -n knative-serving --ignore-not-found -o name).Trim()
    if ($existing) {
        Invoke-Kubectl replace -f $tmpFile
    } else {
        Invoke-Kubectl apply -f $tmpFile
    }

    # Remove common local-dev wildcard domains so Knative only emits *.localhost routes.
    $cleanupPatch = @{
        data = @{
            "127.0.0.1.sslip.io" = $null
            "sslip.io" = $null
            "nip.io" = $null
            "127.0.0.1.nip.io" = $null
        }
    } | ConvertTo-Json -Compress
    $cleanupPatchEscaped = $cleanupPatch.Replace('"', '\"')
    Invoke-Kubectl patch configmap/config-domain --namespace knative-serving --type merge --patch $cleanupPatchEscaped
    Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
}

function Ensure-KnativeFeatureFlags {
    Write-Host "Enabling Knative PVC feature flags ..."
    $featurePatch = @{
        data = @{
            "kubernetes.podspec-persistent-volume-claim" = "enabled"
            "kubernetes.podspec-persistent-volume-write" = "enabled"
        }
    } | ConvertTo-Json -Compress
    $featurePatchEscaped = $featurePatch.Replace('"', '\"')
    Invoke-Kubectl patch configmap/config-features --namespace knative-serving --type merge --patch $featurePatchEscaped
}

function Ensure-TargetNamespace {
    & kubectl create namespace $namespace --dry-run=client -o yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "failed to ensure namespace '$namespace'"
    }
}

function Ensure-OpenClawSecret {
    if (-not $env:GEMINI_API_KEY) {
        throw "GEMINI_API_KEY is not set in the current shell."
    }
    if (-not $env:OPENCLAW_GATEWAY_PASSWORD) {
        throw "OPENCLAW_GATEWAY_PASSWORD is not set in the current shell."
    }

    & kubectl -n $namespace create secret generic openclaw-secrets `
        --from-literal=GEMINI_API_KEY="$($env:GEMINI_API_KEY)" `
        --from-literal=OPENCLAW_GATEWAY_PASSWORD="$($env:OPENCLAW_GATEWAY_PASSWORD)" `
        --dry-run=client -o yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "failed to create/update secret openclaw-secrets in namespace '$namespace'"
    }
}

function Ensure-KourierPortForward {
    $existing = Get-CimInstance Win32_Process |
        Where-Object { $_.Name -match "^kubectl(\.exe)?$" -and $_.CommandLine -match "port-forward\s+svc/kourier\s+8080:80" -and $_.CommandLine -match "-n\s+kourier-system" }

    if ($existing) {
        Write-Host "Kourier port-forward already running on 8080."
        return
    }

    Write-Host "Starting Kourier port-forward in background (8080 -> kourier:80) ..."
    Start-Process -FilePath "kubectl" `
        -ArgumentList @("-n", "kourier-system", "port-forward", "svc/kourier", "8080:80") `
        -WindowStyle Hidden | Out-Null

    Start-Sleep -Seconds 2
}

function Show-OpenClawDiagnostics {
    Write-Host ""
    Write-Host "OpenClaw did not become Ready in time. Collecting diagnostics..."
    Write-Host ""
    Write-Host "=== Knative Services ==="
    & kubectl get ksvc -n $namespace
    Write-Host ""
    Write-Host "=== Service Details ==="
    & kubectl describe ksvc $serviceName -n $namespace
    Write-Host ""
    Write-Host "=== Revisions ==="
    & kubectl get revision -n $namespace
    Write-Host ""
    Write-Host "=== Pods ==="
    & kubectl get pods -n $namespace -o wide
    Write-Host ""
    Write-Host "=== Recent Events ==="
    & kubectl get events -n $namespace --sort-by='.lastTimestamp' | Select-Object -Last 20
    Write-Host ""
    Write-Host "=== Latest Pod Description ==="
    $latestPod = (& kubectl get pods -n $namespace -o name | Sort-Object -Descending | Select-Object -First 1).Trim()
    if ($latestPod) {
        & kubectl describe $latestPod -n $namespace
        Write-Host ""
        Write-Host "=== Latest Pod Logs ==="
        & kubectl logs $latestPod -n $namespace --all-containers=true --timestamps=true --tail=100 2>&1
    }
}

Require-Command "kubectl"

Write-Host "Using current kubectl context: $((& kubectl config current-context).Trim())"
Ensure-KnativeServing
Wait-KnativeControlPlane
Ensure-KnativeFeatureFlags
Ensure-KnativeDomain

Ensure-TargetNamespace
Ensure-OpenClawSecret
Invoke-Kubectl apply -f ".\k8s\openclaw-knative.yaml"
Ensure-KourierPortForward

Write-Host "Waiting for Knative service readiness ..."
try {
    Invoke-Kubectl wait "ksvc/$serviceName" -n $namespace --for=condition=Ready --timeout="$($serviceReadyTimeoutSeconds)s"
}
catch {
    Show-OpenClawDiagnostics
    throw
}

Write-Host ""
Write-Host "OpenClaw deployed."
$liveUrl = (& kubectl get ksvc $serviceName -n $namespace -o jsonpath='{.status.url}').Trim()
if ($liveUrl) {
    $displayUrl = $routeUrl
    try {
        $parsedUrl = [System.Uri]$liveUrl
        $displayUrl = "$($parsedUrl.Scheme)://$($parsedUrl.Host):8080"
    }
    catch {
        $displayUrl = $routeUrl
    }

    Write-Host "URL: $displayUrl"
    if ($liveUrl -notmatch "\.localhost(/|$)") {
        Write-Host "Expected localhost domain for secure browser context. Current domain is not localhost."
        Write-Host "Use HTTPS reverse proxy (for example, Tailscale Serve) or re-run deploy to refresh route host."
    }
} else {
    Write-Host "URL: $routeUrl"
}
Write-Host "If first request is slow, that's normal scale-from-zero cold start."
