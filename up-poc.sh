#!/usr/bin/env bash
# up-poc.sh — brings up the poc environment only
set -euo pipefail
export GODEBUG=http2client=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_DIR="$SCRIPT_DIR/live/poc"

echo "=== Bringing up environment: poc ==="

# Runs a terragrunt command in a module folder, with automatic recovery
# from a stale state lock (usually left behind by a previous apply/destroy
# that got interrupted — a network hang, a Ctrl+C, etc). Detects the
# specific "Error acquiring the state lock" failure, extracts the Lock ID
# Terraform prints in its own error output, gives an 8-second window to
# cancel (in case it's a REAL concurrent run, not a stale one), then
# force-unlocks and retries exactly once.
run_terragrunt() {
  local module_dir="$1"; shift
  local tmp_out
  tmp_out="$(mktemp)"

  set +e
  (cd "$module_dir" && terragrunt "$@") 2>&1 | tee "$tmp_out"
  local exit_code=${PIPESTATUS[0]}
  set -e

  if [[ $exit_code -ne 0 ]] && grep -q "Error acquiring the state lock" "$tmp_out"; then
    local lock_id
    lock_id=$(grep -A1 -E 'ID:' "$tmp_out" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

    if [[ -z "$lock_id" ]]; then
      echo "Lock error detected, but couldn't parse a Lock ID from the output. Manual intervention needed."
      rm -f "$tmp_out"
      return $exit_code
    fi

    echo ""
    echo "!!! State lock detected (ID: $lock_id) !!!"
    echo "This is usually a STALE lock left by a previously interrupted run, not a real"
    echo "concurrent apply. Force-unlocking and retrying in 8 seconds — Ctrl+C now if you"
    echo "know someone/something else is genuinely running terragrunt against this module."
    for i in 8 7 6 5 4 3 2 1; do
      printf "\r  continuing in %ds... " "$i"
      sleep 1
    done
    echo ""

    (cd "$module_dir" && terragrunt force-unlock -force "$lock_id")

    echo "--- retrying: terragrunt $* ---"
    (cd "$module_dir" && terragrunt "$@")
    exit_code=$?
  fi

  rm -f "$tmp_out"
  return $exit_code
}

run() {
  local module="$1"
  echo ""
  echo "--- $module ---"
  run_terragrunt "$LIVE_DIR/$module" apply -auto-approve
}

run vpc
run eks

# Connect kubectl right after the cluster exists, not at the very end.
echo ""
echo "=== Connecting kubectl to acme-cloud-poc-eks ==="
aws eks update-kubeconfig --name "acme-cloud-poc-eks" --region us-east-1

run ecr
run rds
run iam-oidc
run alb-controller

# Cluster Autoscaler runs after alb-controller to reuse the OIDC setup
# (Note: Using the exact folder name matching your directory tree)
run cluster-autoscaler

# EBS CSI driver — also reuses the OIDC setup. Must run before monitoring,
# since Prometheus's PVC needs a working default StorageClass (gp3, via the
# CSI provisioner) to actually bind and leave the node group's default
# in-tree "gp2" StorageClass alone (it no longer works on this K8s version).
run ebs-csi

echo ""
echo "--- external-secrets (step 1: helm + IAM, so CRDs exist) ---"
run_terragrunt "$LIVE_DIR/external-secrets" apply -auto-approve \
  -target=helm_release.eso \
  -target=aws_iam_role_policy.eso_secrets_read \
  -target=kubernetes_service_account.eso

echo ""
echo "--- external-secrets (step 2: CRD-dependent manifests) ---"
run_terragrunt "$LIVE_DIR/external-secrets" apply -auto-approve

# Deploy Prometheus and Grafana monitoring stacks
run monitoring

echo ""
echo "=== Verifying ==="
kubectl get nodes
echo ""
kubectl get pods -n default
echo ""
kubectl get pods -n kube-system
echo ""
kubectl get pods -n monitoring

echo ""
echo "=== poc is up ==="