#!/bin/bash
# CipherWatch — Fast Rebuild: Phases 2-8
# Run this after a cluster state wipe. Assumes k3d cluster + nodes are healthy
# (kubectl get nodes shows Ready) and DNS is working (nslookup registry-1.docker.io resolves).
set -e

echo "=== Pre-flight checks ==="
kubectl get nodes || { echo "Cluster not reachable. Fix that first, then rerun."; exit 1; }
nslookup registry-1.docker.io > /dev/null 2>&1 || { echo "DNS broken. Run: sudo systemctl restart systemd-resolved  — then rerun this script."; exit 1; }
echo "Cluster reachable, DNS working. Proceeding."

echo ""
echo "=== Phase 2: Namespaces ==="
kubectl create namespace application --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace security --dry-run=client -o yaml | kubectl apply -f -
kubectl get ns

echo ""
echo "=== Phase 2: Default-deny NetworkPolicy (baseline) ==="
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: application
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
echo "NOTE: this is a strict default-deny — you'll likely need to add allow rules"
echo "matching whatever you had before (ingress from istio, egress to DNS, etc)."
echo "Skip/adjust this if your original policy was less strict."

echo ""
echo "=== Phase 4: Redeploy application manifests ==="
if [ -d ~/cipherwatch/k8s-manifests ]; then
  kubectl apply -f ~/cipherwatch/k8s-manifests/ -n application || echo "Some manifests may need namespace/paths adjusted — check manually."
else
  echo "No ~/cipherwatch/k8s-manifests directory found — skipping, redeploy manually."
fi

echo ""
echo "=== Phase 4: ArgoCD ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "Waiting for ArgoCD server..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s || echo "ArgoCD still starting, check manually with: kubectl get pods -n argocd"

echo ""
echo "=== Phase 5: Observability (Prometheus + Loki) ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  -n observability --create-namespace --wait --timeout 5m

helm upgrade --install loki grafana/loki-stack -n observability \
  --set grafana.enabled=false \
  --set promtail.enabled=false

echo ""
echo "=== Phase 8: Istio + Kiali ==="
if ! command -v istioctl &>/dev/null; then
  echo "istioctl not found — install it first from https://istio.io/latest/docs/setup/getting-started/#download"
else
  istioctl install --set profile=demo -y

  kubectl label namespace application istio-injection=enabled --overwrite

  if [ -d ~/cipherwatch/k8s-manifests ]; then
    kubectl rollout restart deployment -n application
  fi

  echo "Waiting for Istio control plane..."
  kubectl rollout status deployment/istiod -n istio-system --timeout=180s

  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.30/samples/addons/kiali.yaml -n istio-system || true

  cat <<EOF | kubectl apply -f -
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: application
spec:
  mtls:
    mode: STRICT
EOF
fi

echo ""
echo "=== Phase 6: Falco + Falcosidekick ==="
helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
helm repo update

read -p "Enter your Discord webhook URL: " DISCORD_WEBHOOK

helm upgrade --install falco falcosecurity/falco -n security \
  --set falco.jsonOutput=true \
  --set falco.json_output=true \
  --set falco.http_output.enabled=true \
  --set falco.http_output.url=http://falcosidekick:2801 \
  --wait --timeout 3m

helm upgrade --install falcosidekick falcosecurity/falcosidekick -n security \
  --set config.discord.webhookurl="$DISCORD_WEBHOOK" \
  --wait --timeout 2m

echo ""
echo "=== Rebuild pass complete. Verifying... ==="
kubectl get ns
echo "---"
kubectl get pods -n application
echo "---"
kubectl get pods -n observability
echo "---"
kubectl get pods -n istio-system
echo "---"
kubectl get pods -n security
echo "---"
kubectl get pods -n argocd

echo ""
echo "=== NEXT STEPS (manual, not scripted) ==="
echo "1. Confirm app pods show 2/2 (istio sidecar injected) — may need another"
echo "   'kubectl rollout restart deployment -n application' if they show 1/1."
echo "2. Test Falco -> Discord: kubectl run test-shell --image=busybox -n application -- sleep 3600"
echo "   then kubectl exec -it test-shell -n application -- sh, then 'exit', check Discord."
echo "3. Wazuh (Docker Compose, separate from k3d) should be untouched — verify with:"
echo "   cd ~/wazuh-docker/single-node && sudo docker compose ps"
echo "4. Re-apply ArgoCD Application object once ArgoCD is confirmed healthy."
echo "5. Suricata (host-level, Phase 7) should also be untouched — verify with:"
echo "   systemctl is-active suricata"
