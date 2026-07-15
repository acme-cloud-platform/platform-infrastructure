#!/usr/bin/env bash
# down-qa.sh — tears down the qa environment only
set -euo pipefail
export GODEBUG=http2client=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_DIR="$SCRIPT_DIR/live/qa"

read -p "This will DESTROY the entire 'qa' environment. Type 'qa' to confirm: " CONFIRM
if [[ "$CONFIRM" != "qa" ]]; then
  echo "Confirmation did not match. Aborting, nothing destroyed."
  exit 1
fi

echo "=== Tearing down environment: qa ==="

# Same automatic stale-lock recovery as up-qa.sh — see that file for the
# full explanation. Kept identical between both scripts on purpose.
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
  run_terragrunt "$LIVE_DIR/$module" destroy -auto-approve
}

# Delete app-level Ingress resources FIRST, while the ALB controller is
# still running to actually see and react to the deletion. This is what
# tears down the real ALB + its target groups + the security group the
# controller created for it. If we skip this and go straight to
# `terragrunt destroy` on alb-controller, the controller pod disappears
# with no one left watching — the ALB/target-groups/SG become orphaned in
# AWS, their ENIs stay attached inside the VPC's subnets, and `vpc destroy`
# hangs indefinitely later waiting on ENIs nothing will ever clean up.
echo ""
echo "--- deleting Ingress resources (releases the ALB while the controller can still react) ---"
if aws eks describe-cluster --name acme-cloud-qa-eks --region us-east-1 >/dev/null 2>&1; then
  aws eks update-kubeconfig --name acme-cloud-qa-eks --region us-east-1 >/dev/null
  kubectl delete ingress backend-service -n default --ignore-not-found=true
  kubectl delete ingress frontend-service -n default --ignore-not-found=true

  echo "--- waiting for the ALB to actually disappear before continuing ---"
  for i in $(seq 1 12); do
    ALB_COUNT=$(aws elbv2 describe-load-balancers --region us-east-1 \
      --query "length(LoadBalancers[?contains(LoadBalancerName, 'acmecloudqa')])" \
      --output text 2>/dev/null || echo "0")
    if [[ "$ALB_COUNT" == "0" ]]; then
      echo "Confirmed: no ALB remaining for qa."
      break
    fi
    echo "  still tearing down ALB ($ALB_COUNT remaining) — waiting 10s... ($i/12)"
    sleep 10
    if [[ "$i" == "12" ]]; then
      echo "WARNING: ALB still not gone after 2 minutes. Check the AWS console before continuing —"
      echo "         proceeding with alb-controller destroy now anyway could orphan it."
    fi
  done
else
  echo "(cluster acme-cloud-qa-eks not found — nothing to delete, likely already partially torn down)"
fi

run external-secrets
run alb-controller
run iam-oidc
run rds

# Secrets Manager only SCHEDULES deletion by default (30-day recovery
# window) — that window would block terragrunt from creating a secret with
# the SAME name on the next up-qa.sh run (AWS rejects reusing a name
# that's still in its recovery window). Force-delete immediately instead,
# right after the rds module (which owns this secret) is destroyed.
echo ""
echo "--- force-deleting Secrets Manager secret (skip 30-day recovery window) ---"
aws secretsmanager delete-secret \
  --secret-id acme-cloud-qa-rds-credentials \
  --force-delete-without-recovery \
  --region us-east-1 || echo "(secret already gone or never existed — continuing)"

# Confirm it actually finished deleting before moving on — force-delete is
# usually near-instant but can lag a couple seconds.
echo "--- verifying secret is actually gone ---"
if aws secretsmanager describe-secret --secret-id acme-cloud-qa-rds-credentials --region us-east-1 >/dev/null 2>&1; then
  echo "WARNING: secret still exists, waiting a few seconds and re-checking..."
  sleep 5
  if aws secretsmanager describe-secret --secret-id acme-cloud-qa-rds-credentials --region us-east-1 >/dev/null 2>&1; then
    echo "WARNING: secret still not deleted. Check manually before running up-qa.sh again."
  else
    echo "Confirmed deleted."
  fi
else
  echo "Confirmed deleted."
fi

run ecr
run eks
run vpc

# Clean up the stale kubeconfig context/cluster/user entries left behind
# now that the cluster itself is gone. Leaving these around is exactly
# what caused the earlier connection errors — an old context pointing at
# a cluster that no longer exists (or was recreated with a new API server
# cert) confuses kubectl and any Terraform provider that reads the active
# context, even on a totally unrelated environment's apply.
echo ""
echo "--- removing stale kubectl context for acme-cloud-qa-eks ---"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CONTEXT_NAME="arn:aws:eks:us-east-1:${ACCOUNT_ID}:cluster/acme-cloud-qa-eks"
kubectl config delete-context "$CONTEXT_NAME" 2>/dev/null || echo "(no matching context found — nothing to remove)"
kubectl config delete-cluster "$CONTEXT_NAME" 2>/dev/null || true
kubectl config delete-user "$CONTEXT_NAME" 2>/dev/null || true

echo ""
echo "=== qa is fully destroyed ==="