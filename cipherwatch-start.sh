#!/bin/bash
# CipherWatch — Full Platform Startup Script v2
# Run after every VM reboot. Handles all known cold-boot issues.
# Usage: bash ~/start-cipherwatch.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✘${NC} $1"; }

echo "=============================================="
echo "  CipherWatch Platform Startup v2"
echo "=============================================="

# ── 0. DNS & Network ──────────────────────────────
echo -e "\n${YELLOW}[0] Checking network/DNS...${NC}"
if ! ping -c 1 8.8.8.8 -W 3 &>/dev/null; then
  warn "No internet — restarting network..."
  sudo systemctl restart systemd-resolved NetworkManager 2>/dev/null || true
  sleep 5
fi
if nslookup registry-1.docker.io &>/dev/null; then
  ok "DNS resolving"
else
  warn "DNS still broken — check VM network adapter in VMware"
fi

# ── 1. MTU fix ────────────────────────────────────
echo -e "\n${YELLOW}[1] Applying MTU fix (prevents Helm/image-pull resets)...${NC}"
CURRENT_MTU=$(ip link show ens33 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')
if [ "$CURRENT_MTU" != "1350" ]; then
  sudo nmcli connection modify "Wired connection 1" ethernet.mtu 1350 2>/dev/null || true
  sudo nmcli connection up "Wired connection 1" 2>/dev/null || true
  ok "MTU set to 1350"
else
  ok "MTU already 1350"
fi

# ── 2. Kernel params ──────────────────────────────
echo -e "\n${YELLOW}[2] Kernel parameters...${NC}"
sudo sysctl -w vm.max_map_count=262144 &>/dev/null
ok "vm.max_map_count=262144"

# ── 3. k3d cluster ────────────────────────────────
echo -e "\n${YELLOW}[3] Starting k3d cluster...${NC}"
k3d cluster start cipherwatch 2>/dev/null || true
sleep 10

for i in $(seq 1 30); do
  kubectl get nodes &>/dev/null && break
  sleep 3
done

if kubectl get nodes &>/dev/null; then
  ok "Cluster reachable"
else
  fail "Cluster unreachable — check: sudo docker ps | grep k3d"
  exit 1
fi

# ── 3b. CoreDNS restart (fixes in-cluster DNS after cold boot) ──
echo -e "\n${YELLOW}[3b] Restarting CoreDNS (cold-boot DNS fix)...${NC}"
kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || true
kubectl rollout status deployment/coredns -n kube-system --timeout=60s &>/dev/null && \
  ok "CoreDNS restarted" || warn "CoreDNS restart timed out"
sleep 10

# ── 4. Clean up stuck/Unknown pods ───────────────
echo -e "\n${YELLOW}[4] Clearing stuck/Unknown pods...${NC}"
for ns in application security observability istio-system argocd; do
  kubectl get pods -n $ns --no-headers 2>/dev/null | \
    grep -E "Unknown|Evicted|OOMKilled" | \
    awk '{print $1}' | \
    xargs -r kubectl delete pod -n $ns --force --grace-period=0 2>/dev/null || true
done
ok "Pod cleanup done"

# ── 5. Restart Grafana (always crashes on cold boot) ─
echo -e "\n${YELLOW}[5] Restarting Grafana...${NC}"
kubectl rollout restart deployment/kube-prometheus-grafana \
  -n observability 2>/dev/null && ok "Grafana restarted" || \
  warn "Grafana not found (skip)"

# ── 6. Restart app pods to pick up fresh CoreDNS ──
echo -e "\n${YELLOW}[6] Restarting app pods (ensures fresh sidecar injection)...${NC}"
kubectl delete pods -n application --all --force --grace-period=0 2>/dev/null || true
ok "App pods restarted"

# ── 7. Wazuh ─────────────────────────────────────
echo -e "\n${YELLOW}[7] Starting Wazuh...${NC}"
if [ -d ~/wazuh-docker/single-node ]; then
  cd ~/wazuh-docker/single-node
  sudo docker compose up -d 2>/dev/null
  ok "Wazuh started (takes 60s to be healthy)"
  cd ~
else
  fail "~/wazuh-docker/single-node missing — reinstall Wazuh"
fi

# ── 8. Ollama ─────────────────────────────────────
echo -e "\n${YELLOW}[8] Starting Ollama...${NC}"
if systemctl is-active --quiet ollama; then
  ok "Ollama already running"
else
  sudo systemctl start ollama
  sleep 3
  systemctl is-active --quiet ollama && ok "Ollama started" || \
    fail "Ollama failed to start"
fi

# ── 9. Wait for app pods to be ready ─────────────
echo -e "\n${YELLOW}[9] Waiting for app pods (up to 3 min)...${NC}"
kubectl wait --for=condition=Ready pod -l app=cipherwatch-app \
  -n application --timeout=180s 2>/dev/null && \
  ok "cipherwatch-app pods ready (2/2)" || \
  warn "App pods not ready yet — check: kubectl get pods -n application"

kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=falco \
  -n security --timeout=120s 2>/dev/null && \
  ok "Falco ready" || warn "Falco not ready yet"

# ── 10. Port-forwards ─────────────────────────────
echo -e "\n${YELLOW}[10] Starting port-forwards...${NC}"
VM_IP=$(ip addr show ens33 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
LOGDIR=~/dashboard-logs
mkdir -p "$LOGDIR"

pkill -f "kubectl port-forward" 2>/dev/null || true
sleep 2

fwd() {
  local name=$1 svc=$2 ns=$3 ports=$4
  nohup kubectl port-forward --address 0.0.0.0 "svc/$svc" \
    -n "$ns" $ports > "$LOGDIR/$name.log" 2>&1 &
  ok "$name -> http://$VM_IP:${ports%%:*}"
}

fwd "grafana"        "kube-prometheus-grafana"  "observability" "3000:80"
fwd "kiali"          "kiali"                    "istio-system"  "20001:20001"
fwd "argocd"         "argocd-server"            "argocd"        "8081:443"
fwd "soar-engine"    "soar-engine"              "security"      "8082:8080"
fwd "falco-template" "falco-template"           "security"      "8083:8080"
fwd "cipherwatch"    "cipherwatch-app"          "application"   "8084:80"

# ── Summary ───────────────────────────────────────
GRAFANA_PASS=$(kubectl get secret kube-prometheus-grafana -n observability \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

echo ""
echo "=============================================="
echo "  All services started!"
echo "=============================================="
echo "  CipherWatch app : http://$VM_IP:8084"
echo "  Grafana         : http://$VM_IP:3000"
echo "  Kiali           : http://$VM_IP:20001"
echo "  ArgoCD          : https://$VM_IP:8081"
echo "  SOAR engine     : http://$VM_IP:8082/health"
echo "  Wazuh dashboard : https://$VM_IP:8443"
echo ""
echo "  === Passwords ==="
echo "  Grafana  : admin / ${GRAFANA_PASS:-prom-operator}"
echo "  ArgoCD   : admin / ${ARGOCD_PASS:-check argocd-initial-admin-secret}"
echo "  Wazuh    : admin / SecretPassword"
echo "=============================================="
echo ""
echo "  Wazuh takes 60-90s to fully initialize."
echo "  If app pods are still 0/2 after 3 min, run:"
echo "  kubectl delete pods -n application --all --force --grace-period=0"
