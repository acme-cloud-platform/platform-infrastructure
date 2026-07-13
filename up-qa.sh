#!/usr/bin/env bash
# up-qa.sh — brings up the qa environment only
set -euo pipefail
export GODEBUG=http2client=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_DIR="$SCRIPT_DIR/live/qa"

echo "=== Bringing up environment: qa ==="

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
    lock_id=$(grep -A1 -E '^\s*ID:' "$tmp_out" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

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
# This matters: a STALE kubeconfig context left over from a previous/
# different cluster (or a prior destroy+recreate of this same cluster,
# which gets a new API server cert) can cause confusing, hard-to-diagnose
# connection errors in every later step that talks to the cluster
# (alb-controller, external-secrets) — even though those steps never
# touch kubeconfig themselves, Terraform's kubernetes/helm providers
# still end up reading whatever context is currently active.
echo ""
echo "=== Connecting kubectl to acme-cloud-qa-eks ==="
aws eks update-kubeconfig --name "acme-cloud-qa-eks" --region us-east-1

run ecr

# Note: down-qa.sh force-deletes the RDS Secrets Manager secret
# (--force-delete-without-recovery) instead of leaving it in Secrets
# Manager's default 30-day recovery window. That's WHY this rds apply
# can safely recreate 'acme-cloud-qa-rds-credentials' with the same
# name every time — if it had gone through the default scheduled-deletion
# path instead, this apply would fail with a name-already-scheduled-for-
# deletion error until that window passed.
run rds
run iam-oidc
run alb-controller

echo ""
echo "--- external-secrets (step 1: helm + IAM, so CRDs exist) ---"
run_terragrunt "$LIVE_DIR/external-secrets" apply -auto-approve \
  -target=helm_release.eso \
  -target=aws_iam_role_policy.eso_secrets_read \
  -target=kubernetes_service_account.eso

echo ""
echo "--- external-secrets (step 2: CRD-dependent manifests) ---"
run_terragrunt "$LIVE_DIR/external-secrets" apply -auto-approve

echo ""
echo "=== Verifying ==="
kubectl get nodes
echo ""
kubectl get pods -n default

echo ""
echo "=== qa is up ==="