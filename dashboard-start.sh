#!/bin/bash
# CipherWatch — Start All Dashboards
# Run this once per VM boot/session. Access from your PC browser using the VM's IP.
# Run ./stop-dashboards.sh to kill them all cleanly.

VM_IP=$(ip addr show ens33 | grep "inet " | awk '{print $2}' | cut -d/ -f1)
LOGDIR=~/dashboard-logs
mkdir -p "$LOGDIR"

echo "=== Starting all CipherWatch dashboards ==="
echo "VM IP detected: $VM_IP"
echo ""

start_forward() {
  local name=$1
  local svc=$2
  local ns=$3
  local ports=$4
  nohup kubectl port-forward --address 0.0.0.0 "svc/$svc" -n "$ns" $ports \
    > "$LOGDIR/$name.log" 2>&1 &
  echo "  [$name] PID $! -> http://$VM_IP:${ports%%:*}  (svc/$svc -n $ns)"
}

# Grafana (observability dashboards)
start_forward "grafana" "kube-prometheus-grafana" "observability" "3000:80"

# Kiali (Istio service mesh graph)
start_forward "kiali" "kiali" "istio-system" "20001:20001"

# ArgoCD UI
start_forward "argocd" "argocd-server" "argocd" "8081:443"

# SOAR engine (health/debug access)
start_forward "soar-engine" "soar-engine" "security" "8082:8080"

# Falco beautifier (health/debug access)
start_forward "falco-template" "falco-template" "security" "8083:8080"

# CipherWatch app itself (direct access, bypassing ingress)
start_forward "cipherwatch-app" "cipherwatch-app" "application" "8084:80"

echo ""
echo "=== All dashboards started. Access from your PC browser: ==="
echo "  Grafana:          http://$VM_IP:3000        (admin / prom-operator)"
echo "  Kiali:            http://$VM_IP:20001"
echo "  ArgoCD:           https://$VM_IP:8081        (admin / see: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "  SOAR engine:      http://$VM_IP:8082/health"
echo "  Falco template:   http://$VM_IP:8083/health"
echo "  CipherWatch app:  http://$VM_IP:8084"
echo "  Wazuh dashboard:  https://$VM_IP:8443        (already running via Docker, no forward needed)"
echo ""
echo "Logs are in $LOGDIR/ if any port-forward dies unexpectedly."
echo "Run ./stop-dashboards.sh to stop everything."
