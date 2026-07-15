#!/usr/bin/env bash
# test2-cluster-autoscaler.sh — verify cluster-autoscaler actually scales nodes
set -euo pipefail

DEPLOYMENT="${1:-backend-service}"
NAMESPACE="${2:-default}"
SCALE_UP_REPLICAS="${3:-150}"

echo "=== Test 2: Cluster Autoscaler ==="
echo "Deployment: $DEPLOYMENT (namespace: $NAMESPACE)"
echo ""

echo "--- Current nodes ---"
kubectl get nodes

echo ""
echo "--- Current replica count ---"
ORIGINAL_REPLICAS=$(kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')
echo "Currently: $ORIGINAL_REPLICAS replicas"

echo ""
echo "=== Scaling up to $SCALE_UP_REPLICAS replicas to force pods to not fit ==="
kubectl -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$SCALE_UP_REPLICAS"

echo ""
echo "Watch in two other terminals while this runs:"
echo "  kubectl get pods -w"
echo "  kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler -f"
echo ""
echo "Expect: some pods go Pending -> cluster-autoscaler logs a scale_up event ->"
echo "        a new node appears within ~2-3 minutes."
echo ""
echo "Polling node count for 5 minutes (checks every 15s)..."

START_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
for i in $(seq 1 20); do
  CURRENT_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
  echo "  [$i/20] nodes: $CURRENT_NODES (started at $START_NODES)"
  if [[ "$CURRENT_NODES" -gt "$START_NODES" ]]; then
    echo ""
    echo ">>> Scale-up confirmed: node count went from $START_NODES to $CURRENT_NODES <<<"
    break
  fi
  sleep 15
done

kubectl get nodes

echo ""
echo "=== Scaling back down to $ORIGINAL_REPLICAS replicas ==="
kubectl -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$ORIGINAL_REPLICAS"

echo ""
echo "Node scale-DOWN is NOT instant on purpose (avoids flapping). Defaults:"
echo "  - scale-down-delay-after-add: 10 min after any scale-up before scale-down is even considered"
echo "  - scale-down-unneeded-time:   node must sit underutilized for 10 more min before removal"
echo "So expect the extra node(s) to disappear roughly 10-20 min after this point, not sooner."
echo ""
echo "Check back later with: kubectl get nodes"
echo "Or watch it happen live:  kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler -f"
