#!/usr/bin/env bash
# test1-monitoring.sh — verify Prometheus + Grafana are actually working
set -euo pipefail

NAMESPACE="monitoring"

echo "=== Test 1: Monitoring ==="

echo ""
echo "--- Pod health ---"
kubectl -n "$NAMESPACE" get pods

echo ""
echo "--- PVC (Prometheus storage) ---"
kubectl -n "$NAMESPACE" get pvc

echo ""
echo "--- Grafana admin password ---"
GRAFANA_PW=$(kubectl -n "$NAMESPACE" get secret grafana -o jsonpath="{.data.admin-password}" | base64 -d)
echo "username: admin"
echo "password: $GRAFANA_PW"

echo ""
echo "=== Manual steps ==="
echo "1. Port-forward Prometheus and check targets are all UP:"
echo "   kubectl -n $NAMESPACE port-forward svc/prometheus-server 9090:80"
echo "   open http://localhost:9090/targets"
echo ""
echo "2. Port-forward Grafana and log in with the credentials above:"
echo "   kubectl -n $NAMESPACE port-forward svc/grafana 3000:80"
echo "   open http://localhost:3000"
echo ""
echo "3. Add Prometheus as a data source (Connections -> Data sources -> Add -> Prometheus):"
echo "   URL: http://prometheus-server.monitoring.svc.cluster.local"
echo "   Save & Test -> should say 'Successfully queried the Prometheus API'"
echo ""
echo "4. Import a ready-made dashboard: Dashboards -> New -> Import -> ID 1860 (Node Exporter Full)"
echo "   Pick the Prometheus data source you just added -> Import"
echo "   You should see live CPU/memory/disk/network graphs for all 3 nodes."
echo ""
echo "If targets are UP, data source test succeeds, and dashboard 1860 shows real"
echo "graphs (not 'No data') -- monitoring is confirmed working end to end."
