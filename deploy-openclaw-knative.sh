#!/usr/bin/env bash
set -euo pipefail

KNATIVE_VERSION="knative-v1.22.0"
KOURIER_VERSION="knative-v1.22.0"
NAMESPACE="agents"
SERVICE_NAME="openclaw"
DOMAIN_SUFFIX="localhost"
LOCAL_PORT="8080"
ROUTE_HOST="${SERVICE_NAME}.${NAMESPACE}.${DOMAIN_SUFFIX}"
SERVICE_READY_TIMEOUT_SECONDS="300s"
MANIFEST_PATH="./k8s/openclaw-knative.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-port)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --local-port. Use 8080 or 80." >&2
        exit 1
      fi
      shift
      LOCAL_PORT="${1:-}"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: ./deploy-openclaw-knative.sh [--local-port 8080|80]" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "${LOCAL_PORT}" != "8080" && "${LOCAL_PORT}" != "80" ]]; then
  echo "Invalid --local-port '${LOCAL_PORT}'. Allowed values: 8080 or 80." >&2
  exit 1
fi

if [[ "${LOCAL_PORT}" == "80" ]]; then
  ROUTE_URL="http://${ROUTE_HOST}"
else
  ROUTE_URL="http://${ROUTE_HOST}:${LOCAL_PORT}"
fi

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Required command '$name' is not available on PATH." >&2
    exit 1
  fi
}

ensure_knative_serving() {
  if ! kubectl get namespace knative-serving >/dev/null 2>&1; then
    echo "Installing Knative Serving ${KNATIVE_VERSION} ..."
    kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-crds.yaml"
    kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-core.yaml"
  else
    echo "Knative Serving namespace already present. Skipping core install."
  fi

  echo "Installing/refreshing Kourier ${KOURIER_VERSION} ..."
  kubectl apply -f "https://github.com/knative-extensions/net-kourier/releases/download/${KOURIER_VERSION}/kourier.yaml"
  kubectl patch configmap/config-network -n knative-serving --type merge \
    --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'
}

wait_knative_control_plane() {
  echo "Waiting for Knative control plane readiness ..."
  kubectl wait deployment/activator -n knative-serving --for=condition=Available --timeout=300s
  kubectl wait deployment/autoscaler -n knative-serving --for=condition=Available --timeout=300s
  kubectl wait deployment/controller -n knative-serving --for=condition=Available --timeout=300s
  kubectl wait deployment/webhook -n knative-serving --for=condition=Available --timeout=300s
  kubectl wait deployment/net-kourier-controller -n knative-serving --for=condition=Available --timeout=300s
}

ensure_knative_feature_flags() {
  echo "Enabling Knative PVC feature flags ..."
  kubectl patch configmap/config-features -n knative-serving --type merge \
    --patch '{"data":{"kubernetes.podspec-persistent-volume-claim":"enabled","kubernetes.podspec-persistent-volume-write":"enabled"}}'
}

ensure_knative_domain() {
  echo "Configuring Knative domain suffix: ${DOMAIN_SUFFIX}"
  local tmp_file
  tmp_file="$(mktemp)"
  cat >"${tmp_file}" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-domain
  namespace: knative-serving
data:
  ${DOMAIN_SUFFIX}: ""
EOF

  if kubectl get configmap config-domain -n knative-serving >/dev/null 2>&1; then
    kubectl replace -f "${tmp_file}"
  else
    kubectl apply -f "${tmp_file}"
  fi

  kubectl patch configmap/config-domain -n knative-serving --type merge \
    --patch '{"data":{"127.0.0.1.sslip.io":null,"sslip.io":null,"nip.io":null,"127.0.0.1.nip.io":null}}'
  rm -f "${tmp_file}"
}

ensure_target_namespace() {
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
}

ensure_openclaw_secret() {
  if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    echo "GEMINI_API_KEY is not set in the current shell." >&2
    exit 1
  fi
  if [[ -z "${OPENCLAW_GATEWAY_PASSWORD:-}" ]]; then
    echo "OPENCLAW_GATEWAY_PASSWORD is not set in the current shell." >&2
    exit 1
  fi

  local secret_env_file
  secret_env_file="$(mktemp)"
  chmod 600 "${secret_env_file}"
  cat >"${secret_env_file}" <<EOF
GEMINI_API_KEY=${GEMINI_API_KEY}
OPENCLAW_GATEWAY_PASSWORD=${OPENCLAW_GATEWAY_PASSWORD}
EOF

  if ! kubectl -n "${NAMESPACE}" create secret generic openclaw-secrets \
    --from-env-file="${secret_env_file}" \
    --dry-run=client -o yaml | kubectl apply -f -; then
    rm -f "${secret_env_file}"
    return 1
  fi
  rm -f "${secret_env_file}"
}

ensure_kourier_port_forward() {
  if pgrep -f "kubectl -n kourier-system port-forward svc/kourier ${LOCAL_PORT}:80" >/dev/null 2>&1; then
    echo "Kourier port-forward already running on ${LOCAL_PORT}."
    return
  fi

  if [[ "${LOCAL_PORT}" == "80" ]]; then
    if [[ "$(id -u)" -ne 0 ]]; then
      echo "Port 80 requires root. Re-running port-forward with sudo ..."
      nohup sudo kubectl -n kourier-system port-forward svc/kourier 80:80 >/tmp/openclaw-kourier-port-forward.log 2>&1 &
    else
      nohup kubectl -n kourier-system port-forward svc/kourier 80:80 >/tmp/openclaw-kourier-port-forward.log 2>&1 &
    fi
  else
    nohup kubectl -n kourier-system port-forward svc/kourier "${LOCAL_PORT}:80" >/tmp/openclaw-kourier-port-forward.log 2>&1 &
  fi

  echo "Starting Kourier port-forward in background (${LOCAL_PORT} -> kourier:80) ..."
  sleep 2
}

show_openclaw_diagnostics() {
  echo
  echo "OpenClaw did not become Ready in time. Collecting diagnostics..."
  echo
  echo "=== Knative Services ==="
  kubectl get ksvc -n "${NAMESPACE}" || true
  echo
  echo "=== Service Details ==="
  kubectl describe ksvc "${SERVICE_NAME}" -n "${NAMESPACE}" || true
  echo
  echo "=== Revisions ==="
  kubectl get revision -n "${NAMESPACE}" || true
  echo
  echo "=== Pods ==="
  kubectl get pods -n "${NAMESPACE}" -o wide || true
  echo
  echo "=== Recent Events ==="
  kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -20 || true
  echo
  local latest_pod
  latest_pod="$(kubectl get pods -n "${NAMESPACE}" -o name 2>/dev/null | sort -r | head -n 1 || true)"
  if [[ -n "${latest_pod}" ]]; then
    echo "=== Latest Pod Description ==="
    kubectl describe "${latest_pod}" -n "${NAMESPACE}" || true
    echo
    echo "=== Latest Pod Logs ==="
    kubectl logs "${latest_pod}" -n "${NAMESPACE}" --all-containers=true --timestamps=true --tail=100 || true
  fi
}

require_command "kubectl"

echo "Using current kubectl context: $(kubectl config current-context)"
ensure_knative_serving
wait_knative_control_plane
ensure_knative_feature_flags
ensure_knative_domain
ensure_target_namespace
ensure_openclaw_secret
kubectl apply -f "${MANIFEST_PATH}"
ensure_kourier_port_forward

echo "Waiting for Knative service readiness ..."
if ! kubectl wait "ksvc/${SERVICE_NAME}" -n "${NAMESPACE}" --for=condition=Ready --timeout="${SERVICE_READY_TIMEOUT_SECONDS}"; then
  show_openclaw_diagnostics
  exit 1
fi

echo
echo "OpenClaw deployed."
live_url="$(kubectl get ksvc "${SERVICE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.url}' || true)"
live_url="$(echo "${live_url}" | tr -d '\r\n')"
if [[ -n "${live_url}" ]]; then
  scheme="${live_url%%://*}"
  if [[ "${scheme}" == "${live_url}" ]]; then
    scheme="http"
  fi
  live_no_scheme="${live_url#*://}"
  live_host="${live_no_scheme%%/*}"
  live_host="${live_host%%:*}"
  if [[ "${LOCAL_PORT}" == "80" ]]; then
    display_url="${scheme}://${live_host}"
  else
    display_url="${scheme}://${live_host}:${LOCAL_PORT}"
  fi
  echo "URL: ${display_url}"
  if [[ "${live_host}" != *.localhost ]]; then
    echo "Expected localhost domain for secure browser context. Current domain is not localhost."
    echo "Use HTTPS reverse proxy (for example, Tailscale Serve) or re-run deploy to refresh route host."
  fi
else
  echo "URL: ${ROUTE_URL}"
fi
echo "If first request is slow, that's normal scale-from-zero cold start."
