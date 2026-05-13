# OpenClaw on Knative (minikube/kind)

This setup runs OpenClaw Gateway on Knative with scale-to-zero and local routing that works with strict origin/auth checks.

## Files

- `k8s\openclaw-knative.yaml`: Namespace, PVC, OpenClaw config, Knative Service
- `deploy-openclaw-knative.ps1`: Windows deployment script
- `deploy-openclaw-knative.sh`: Linux/macOS deployment script

## Prerequisites

- `kubectl` installed and pointed at your cluster
- Cluster running (`minikube` or `kind`)
- Env vars set:
  - `GEMINI_API_KEY`
  - `OPENCLAW_GATEWAY_PASSWORD`

## One-command deploy (Windows)

```powershell
cd "D:\Projects\OpneClaw k8s"
$env:GEMINI_API_KEY="your_key_here"
$env:OPENCLAW_GATEWAY_PASSWORD="strong_password_here"
.\deploy-openclaw-knative.ps1
```

## One-command deploy (Linux/macOS)

```bash
cd "/path/to/OpneClaw k8s"
export GEMINI_API_KEY="your_key_here"
export OPENCLAW_GATEWAY_PASSWORD="strong_password_here"
chmod +x ./deploy-openclaw-knative.sh
./deploy-openclaw-knative.sh
```

Both scripts install/refresh Knative Serving + Kourier if needed, configure Knative domain/features, deploy OpenClaw, and print an access URL with `:8080` (for local Kourier port-forward access).

## Access URL

Use:

- `http://openclaw.agents.localhost:8080`

`ksvc.status.url` often omits the port. The scripts normalize output to include `:8080`.

## Current local security model

- `gateway.bind: "loopback"`
- `gateway.auth.mode: "password"`
- `gateway.controlUi.dangerouslyDisableDeviceAuth: true` (local dev convenience)
- `gateway.controlUi.allowedOrigins` includes:
  - `http://127.0.0.1:8080`
  - `http://localhost:8080`
  - `http://openclaw.agents.localhost:8080`
  - `http://openclaw.agents.127.0.0.1.sslip.io:8080`

## Scale-to-zero behavior

Configured on the Knative revision:

- `autoscaling.knative.dev/min-scale: "0"`
- `autoscaling.knative.dev/max-scale: "1"`
- `autoscaling.knative.dev/scale-to-zero-pod-retention-period: "5m"`

## Optional HTTPS via Tailscale Serve

```bash
kubectl -n kourier-system port-forward svc/kourier 8080:80
tailscale serve --https=443 http://127.0.0.1:8080
tailscale serve status
```

If you use the Tailscale HTTPS URL, add that exact origin to `gateway.controlUi.allowedOrigins` and redeploy.

## Useful commands

```bash
kubectl -n agents get ksvc openclaw
kubectl -n agents get pods
kubectl -n agents logs -l serving.knative.dev/service=openclaw --tail=200
kubectl -n agents get secret openclaw-secrets -o yaml
```

