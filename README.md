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
# Optional: use local port 80 instead of 8080
.\deploy-openclaw-knative.ps1 -LocalPort 80
```

## One-command deploy (Linux/macOS)

```bash
cd "/path/to/OpneClaw k8s"
export GEMINI_API_KEY="your_key_here"
export OPENCLAW_GATEWAY_PASSWORD="strong_password_here"
chmod +x ./deploy-openclaw-knative.sh
./deploy-openclaw-knative.sh
# Optional: use local port 80 instead of 8080
./deploy-openclaw-knative.sh --local-port 80
```

Both scripts install/refresh Knative Serving + Kourier if needed, configure Knative domain/features, deploy OpenClaw, and print an access URL using your selected local port.
Default is `8080`; optional alternate is `80`.

## Why Knative + Kourier

- Knative Serving provides serverless behavior on Kubernetes: request-based autoscaling, cold starts, and scale-to-zero.
- Kourier is the Knative ingress layer that receives HTTP traffic for Knative Services.
- A plain Kubernetes Deployment/Service/Ingress works for exposure, but it is not the same serverless model by default (typically at least one replica stays running).

## Access URL

Use (default mode):

- `http://openclaw.agents.localhost:8080`

If you run with port 80 mode, use:

- `http://openclaw.agents.localhost`

`ksvc.status.url` often omits the port. The scripts normalize output to match your selected local port.

## Current local security model

- `gateway.bind: "loopback"`
- `gateway.auth.mode: "password"`
- `gateway.controlUi.dangerouslyDisableDeviceAuth: true` (set for local Knative/Kourier usability)
- `gateway.controlUi.allowedOrigins` includes:
  - `http://127.0.0.1`
  - `http://localhost`
  - `http://openclaw.agents.localhost`
  - `http://127.0.0.1:8080`
  - `http://localhost:8080`
  - `http://openclaw.agents.localhost:8080`

## Security concern (important)

`dangerouslyDisableDeviceAuth: true` disables Control UI device-pairing protection. This is less secure and should be used only for local development.

Safer alternatives:

1. Keep device auth enabled and approve pairing requests:

```powershell
$pod = kubectl -n agents get pods -l serving.knative.dev/service=openclaw -o jsonpath='{.items[0].metadata.name}'
kubectl -n agents exec $pod -- openclaw devices list
kubectl -n agents exec $pod -- openclaw devices approve <requestId>
```

2. Use Tailscale Serve identity-aware flow (`gateway.auth.allowTailscale: true`) instead of disabling device auth.

## Scale-to-zero behavior

Configured on the Knative revision:

- `autoscaling.knative.dev/min-scale: "0"`
- `autoscaling.knative.dev/max-scale: "1"`
- `autoscaling.knative.dev/scale-to-zero-pod-retention-period: "5m"`

## Optional HTTPS via Tailscale Serve

Use this for a more secure exposure path than local plain HTTP.

1. Keep local Kourier forwarding:

```bash
kubectl -n kourier-system port-forward svc/kourier 8080:80
```

If you selected local port 80 in deploy scripts, use:

```bash
kubectl -n kourier-system port-forward svc/kourier 80:80
```

2. Publish HTTPS with Tailscale:

```bash
tailscale serve --https=443 http://127.0.0.1:8080
tailscale serve status
```

If you selected local port 80 in deploy scripts, use:

```bash
tailscale serve --https=443 http://127.0.0.1:80
tailscale serve status
```

3. Add the exact `https://<host>.<tailnet>.ts.net` origin to `gateway.controlUi.allowedOrigins` in `k8s\openclaw-knative.yaml`, then redeploy.

4. For tighter auth, enable Tailscale identity-based gateway auth in `openclaw.json`:

```json5
{
  gateway: {
    auth: {
      mode: "password",
      allowTailscale: true
    }
  }
}
```

## Why Tailscale is not fully automated in this repo

Tailscale requires host-level setup outside Kubernetes manifests:

- `tailscaled` daemon installed/running on the machine
- machine logged into your tailnet (`tailscale up`) with your org policy
- permission to bind Serve ports and publish HTTPS in your tailnet

Because those are environment/account-specific, the deploy scripts cannot safely/portably auto-complete them for every machine.

## Useful commands

```bash
kubectl -n agents get ksvc openclaw
kubectl -n agents get pods
kubectl -n agents logs -l serving.knative.dev/service=openclaw --tail=200
kubectl -n agents get secret openclaw-secrets -o yaml
```

