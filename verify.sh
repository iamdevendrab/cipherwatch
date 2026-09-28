#!/bin/bash
# CipherWatch — Full Phase Verification v2
# Run after startup script to see exact completion status.
# Usage: bash ~/verify-cipherwatch.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARNS=()

pass() { echo -e "  ${GREEN}✔${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✘${NC} $1"; FAIL=$((FAIL+1)); WARNS+=("$1"); }
hdr()  { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

# ── Phase 0-1: Tooling ────────────────────────────
hdr "Phase 0-1: Host & Core Tooling"
command -v docker    &>/dev/null && pass "Docker installed"    || fail "Docker missing"
command -v kubectl   &>/dev/null && pass "kubectl installed"   || fail "kubectl missing"
command -v k3d       &>/dev/null && pass "k3d installed"       || fail "k3d missing"
command -v helm      &>/dev/null && pass "Helm installed"      || fail "Helm missing"
command -v istioctl  &>/dev/null && pass "istioctl installed"  || fail "istioctl missing"
command -v ollama    &>/dev/null && pass "Ollama installed"    || fail "Ollama missing"
command -v suricata  &>/dev/null && pass "Suricata installed"  || fail "Suricata missing"
kubectl get nodes &>/dev/null    && pass "k3d cluster reachable" || fail "Cluster unreachable"
kubectl get nodes 2>/dev/null | grep -q Ready && pass "All nodes Ready" || fail "Nodes not Ready"

# ── Phase 2: Namespaces ───────────────────────────
hdr "Phase 2: Namespaces & Baseline Security"
for ns in application platform observability security istio-system argocd; do
  kubectl get ns $ns &>/dev/null && pass "namespace: $ns" || fail "namespace MISSING: $ns"
done

# ── Phase 3: CI/CD ───────────────────────────────
hdr "Phase 3: CI/CD Pipeline"
test -f ~/cipherwatch/app/Dockerfile \
  && pass "Dockerfile exists" || fail "Dockerfile missing"
test -f ~/cipherwatch/.github/workflows/ci-cd.yml \
  && pass "CI/CD workflow exists" || fail "ci-cd.yml missing"
git -C ~/cipherwatch log --oneline -1 &>/dev/null \
  && pass "Git repo initialized" || fail "Git not initialized"
COMMITS=$(git -C ~/cipherwatch log --oneline 2>/dev/null | wc -l)
[ "$COMMITS" -ge 2 ] \
  && pass "Git has $COMMITS commits (pipeline ran)" \
  || fail "Only $COMMITS commit — pipeline may not have run"

# ── Phase 4: ArgoCD ──────────────────────────────
hdr "Phase 4: ArgoCD GitOps"
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server \
  2>/dev/null | grep -q Running \
  && pass "ArgoCD server running" || fail "ArgoCD server not running"
SYNC=$(kubectl get application cipherwatch-app -n argocd \
  -o jsonpath='{.status.sync.status}' 2>/dev/null)
HEALTH=$(kubectl get application cipherwatch-app -n argocd \
  -o jsonpath='{.status.health.status}' 2>/dev/null)
[ "$SYNC" = "Synced" ] \
  && pass "ArgoCD app: Synced" || fail "ArgoCD app: ${SYNC:-missing} (not Synced)"
[ "$HEALTH" = "Healthy" ] \
  && pass "ArgoCD app: Healthy" || fail "ArgoCD app: ${HEALTH:-missing} (not Healthy)"
kubectl get deployment cipherwatch-app -n application &>/dev/null \
  && pass "cipherwatch-app deployment exists" \
  || fail "cipherwatch-app deployment missing"

# ── Phase 5: Observability ───────────────────────
hdr "Phase 5: Observability Stack"
helm status kube-prometheus -n observability &>/dev/null \
  && pass "kube-prometheus-stack installed" \
  || fail "kube-prometheus-stack missing"
helm status loki -n observability &>/dev/null \
  && pass "Loki installed" || fail "Loki missing"
kubectl get pods -n observability -l app.kubernetes.io/name=grafana \
  2>/dev/null | grep -q "3/3\|2/3.*Running\|1/1.*Running" \
  && pass "Grafana pod running" \
  || fail "Grafana pod NOT running (may still be starting)"
kubectl get pods -n observability 2>/dev/null | grep -q "prometheus.*Running" \
  && pass "Prometheus running" || fail "Prometheus not running"
kubectl get pods -n observability 2>/dev/null | grep "loki" | grep -q Running \
  && pass "Loki pod running" || fail "Loki pod not running"

# ── Phase 6: Falco ───────────────────────────────
hdr "Phase 6: Runtime Security (Falco)"
helm status falco -n security &>/dev/null \
  && pass "Falco installed" || fail "Falco not installed"
FALCO_PODS=$(kubectl get pods -n security -l app.kubernetes.io/name=falco \
  --no-headers 2>/dev/null | grep -c "2/2.*Running")
[ "$FALCO_PODS" -ge 3 ] \
  && pass "Falco: $FALCO_PODS/3 pods 2/2 Running" \
  || fail "Falco: only $FALCO_PODS pods Running (want 3)"
helm status falcosidekick -n security &>/dev/null \
  && pass "Falcosidekick installed" || fail "Falcosidekick not installed"
kubectl logs -n security -l app.kubernetes.io/name=falcosidekick \
  --tail 30 2>/dev/null | grep -q "Enabled Outputs" \
  && pass "Falcosidekick has active outputs" \
  || fail "Falcosidekick outputs not confirmed"
FALCO_POD=$(kubectl get pod -n security -l app.kubernetes.io/name=falco \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$FALCO_POD" ]; then
  JSON_OUT=$(kubectl exec -n security "$FALCO_POD" -c falco -- \
    cat /etc/falco/falco.yaml 2>/dev/null | grep "json_output" | head -1)
  echo "$JSON_OUT" | grep -q "true" \
    && pass "Falco json_output: true" \
    || fail "Falco json_output is NOT true"
  HTTP_OUT=$(kubectl exec -n security "$FALCO_POD" -c falco -- \
    cat /etc/falco/falco.yaml 2>/dev/null | grep -A3 "http_output:" | grep "enabled")
  echo "$HTTP_OUT" | grep -q "true" \
    && pass "Falco http_output: enabled" \
    || fail "Falco http_output NOT enabled"
fi
kubectl get pods -n security -l app=falco-template \
  2>/dev/null | grep -q Running \
  && pass "Falco beautifier (falco-template) running" \
  || fail "Falco beautifier not running"

# ── Phase 7: Suricata ────────────────────────────
hdr "Phase 7: Network Security (Suricata)"
systemctl is-active --quiet suricata \
  && pass "Suricata service active" || fail "Suricata not running"
test -f /var/log/suricata/eve.json \
  && pass "eve.json exists" || fail "eve.json missing"
LINES=$(wc -l < /var/log/suricata/eve.json 2>/dev/null)
[ "${LINES:-0}" -gt 0 ] \
  && pass "eve.json has $LINES events" || fail "eve.json is empty"

# ── Phase 8: Istio + Kiali ───────────────────────
hdr "Phase 8: Service Mesh (Istio + Kiali)"
kubectl get pods -n istio-system -l app=istiod \
  2>/dev/null | grep -q Running \
  && pass "istiod running" || fail "istiod not running"
kubectl get pods -n istio-system -l app=istio-ingressgateway \
  2>/dev/null | grep -q Running \
  && pass "Istio ingress gateway running" \
  || fail "Ingress gateway not running"
kubectl get pods -n istio-system -l app.kubernetes.io/name=kiali \
  2>/dev/null | grep -q Running \
  && pass "Kiali running" || fail "Kiali not running"
INJECT=$(kubectl get ns application \
  -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null)
[ "$INJECT" = "enabled" ] \
  && pass "Sidecar injection enabled on application ns" \
  || fail "Sidecar injection NOT enabled"
APP_PODS_READY=$(kubectl get pods -n application -l app=cipherwatch-app \
  --no-headers 2>/dev/null | grep -c "2/2.*Running")
[ "$APP_PODS_READY" -ge 1 ] \
  && pass "App pods have Istio sidecar (2/2 Running: $APP_PODS_READY pods)" \
  || fail "App pods MISSING Istio sidecar (still 0/2 or 1/2)"
MTLS=$(kubectl get peerauthentication default -n application \
  -o jsonpath='{.spec.mtls.mode}' 2>/dev/null)
[ "$MTLS" = "STRICT" ] \
  && pass "Strict mTLS applied" || fail "Strict mTLS NOT applied"
DNS_EXCL=$(kubectl get deployment cipherwatch-app -n application \
  -o jsonpath='{.spec.template.metadata.annotations}' 2>/dev/null)
echo "$DNS_EXCL" | grep -q "excludeOutboundPorts" \
  && pass "DNS exclusion annotation present (prevents sidecar boot loop)" \
  || fail "DNS exclusion annotation MISSING — pods will fail after reboot"

# ── Phase 9: Wazuh ───────────────────────────────
hdr "Phase 9: SIEM (Wazuh)"
sysctl vm.max_map_count 2>/dev/null | grep -q 262144 \
  && pass "vm.max_map_count=262144" || fail "vm.max_map_count wrong"
sudo docker ps --filter name=wazuh.manager --filter status=running \
  -q 2>/dev/null | grep -q . \
  && pass "Wazuh manager running" || fail "Wazuh manager not running"
sudo docker ps --filter name=wazuh.indexer --filter status=running \
  -q 2>/dev/null | grep -q . \
  && pass "Wazuh indexer running" || fail "Wazuh indexer not running"
sudo docker ps --filter name=wazuh.dashboard --filter status=running \
  -q 2>/dev/null | grep -q . \
  && pass "Wazuh dashboard running" || fail "Wazuh dashboard not running"
curl -sk -u admin:SecretPassword --max-time 5 \
  https://localhost:9200 2>/dev/null | grep -q cluster_name \
  && pass "Wazuh indexer API responding" \
  || fail "Wazuh indexer API not responding (may still be starting)"

# ── Phase 9.4: Log Sources ───────────────────────
hdr "Phase 9.4: Log Sources → Wazuh"
kubectl logs -n security -l app.kubernetes.io/name=falcosidekick \
  --tail 30 2>/dev/null | grep -q "Syslog" \
  && pass "Falcosidekick: Syslog output active" \
  || fail "Falcosidekick: Syslog NOT active"
sudo docker exec single-node-wazuh.manager-1 \
  grep -q "connection>syslog" /var/ossec/etc/ossec.conf 2>/dev/null \
  && pass "Wazuh: syslog remote listener configured" \
  || fail "Wazuh: syslog listener NOT configured"
sudo docker exec single-node-wazuh.manager-1 \
  test -f /var/log/suricata/eve.json 2>/dev/null \
  && pass "Wazuh: Suricata eve.json mounted" \
  || fail "Wazuh: Suricata eve.json NOT mounted"
sudo docker exec single-node-wazuh.manager-1 \
  grep -q "eve.json" /var/ossec/etc/ossec.conf 2>/dev/null \
  && pass "Wazuh: eve.json localfile configured" \
  || fail "Wazuh: eve.json localfile NOT configured"

# ── Phase 10: SOAR ───────────────────────────────
hdr "Phase 10: SOAR Engine"
kubectl get pods -n security -l app=soar-engine \
  2>/dev/null | grep -q Running \
  && pass "SOAR engine pod running" || fail "SOAR engine not running"
curl -s --max-time 5 http://localhost:8082/health \
  2>/dev/null | grep -q "ok" \
  && pass "SOAR /health responding" \
  || fail "SOAR /health not responding (port-forward running?)"
kubectl get sa soar-engine -n security &>/dev/null \
  && pass "SOAR ServiceAccount exists" \
  || fail "SOAR ServiceAccount missing"

# ── Phase 11: Ollama ─────────────────────────────
hdr "Phase 11: AI Layer (Ollama)"
systemctl is-active --quiet ollama \
  && pass "Ollama service running" || fail "Ollama not running"
curl -s --max-time 5 http://127.0.0.1:11434 \
  2>/dev/null | grep -q "running" \
  && pass "Ollama API responding" || fail "Ollama API not responding"
ollama list 2>/dev/null | grep -q "llama3.1:8b" \
  && pass "llama3.1:8b model ready" || fail "llama3.1:8b NOT pulled"

# ── Phase 12: End-to-End ─────────────────────────
hdr "Phase 12: End-to-End Pipeline (manual)"
echo "  Run these steps to verify the full chain:"
echo "  1. git push → GitHub Actions → CI passes → Discord CI alert"
echo "  2. ArgoCD auto-syncs → new pod deployed"
echo "  3. kubectl exec -it <app-pod> -n application -- sh → exit"
echo "     → Discord Falco alert (beautified embed)"
echo "     → Wazuh Threat Hunting shows the event"
echo "  4. kubectl logs -n security -l app=soar-engine --tail 20"
echo "     → Shows AI analysis of the alert"

# ── Summary ───────────────────────────────────────
TOTAL=$((PASS+FAIL))
PERCENT=$((PASS*100/TOTAL))
echo ""
echo "══════════════════════════════════════════════"
echo -e "  Score: ${GREEN}$PASS${NC}/${TOTAL} checks  (${PERCENT}%)"

if [ ${#WARNS[@]} -gt 0 ]; then
  echo ""
  echo -e "  ${RED}Failing checks:${NC}"
  for w in "${WARNS[@]}"; do
    echo "    ✘ $w"
  done
fi
echo "══════════════════════════════════════════════"

# ── Quick passwords ───────────────────────────────
echo ""
echo "  === Passwords ==="
GRAFANA_PASS=$(kubectl get secret kube-prometheus-grafana -n observability \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
echo "  Grafana  : admin / ${GRAFANA_PASS:-run: kubectl get secret kube-prometheus-grafana -n observability -o jsonpath='{.data.admin-password}' | base64 -d}"
echo "  ArgoCD   : admin / ${ARGOCD_PASS:-check argocd-initial-admin-secret}"
echo "  Wazuh    : admin / SecretPassword"
echo ""
