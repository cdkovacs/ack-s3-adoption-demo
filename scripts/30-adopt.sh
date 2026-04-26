#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env AWS_REGION BUCKET_PREFIX

if [[ ! -f "$BUCKET_NAME_FILE" ]]; then
  echo "!! $BUCKET_NAME_FILE missing — run 10-tf-create.sh first" >&2
  exit 1
fi
EXISTING_BUCKET=$(cat "$BUCKET_NAME_FILE")

# Generate (or reuse) the second bucket name. ACK creates this one from spec —
# nothing in AWS yet. Suffix is independent of the terraform bucket so a re-run
# without --reset still works.
if [[ -f "$NEW_BUCKET_NAME_FILE" ]]; then
  NEW_BUCKET=$(cat "$NEW_BUCKET_NAME_FILE")
  echo ">> reusing new-bucket name from prior run: $NEW_BUCKET"
else
  NEW_BUCKET="${BUCKET_PREFIX}-new-$(date +%s)"
  echo "$NEW_BUCKET" > "$NEW_BUCKET_NAME_FILE"
  echo ">> generated new-bucket name: $NEW_BUCKET"
fi

# Sanity-check the two paths so the demo output makes the branch obvious.
echo ">> pre-state in AWS:"
if aws s3api head-bucket --bucket "$EXISTING_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
  echo "   $EXISTING_BUCKET  exists  → adopt-or-create will ADOPT"
else
  echo "   $EXISTING_BUCKET  MISSING (terraform phase did not run?)"
fi
if aws s3api head-bucket --bucket "$NEW_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
  echo "   $NEW_BUCKET  exists already (re-run) → adopt-or-create will ADOPT"
else
  echo "   $NEW_BUCKET  not present → adopt-or-create will CREATE"
fi

apply_bucket_cr() {
  local name=$1 managed_by=$2
  echo ">> applying Bucket CR for $name (ManagedBy=$managed_by)"
  BUCKET_NAME="$name" MANAGED_BY="$managed_by" \
    envsubst < "$DEMO_DIR/manifests/adopted-bucket.yaml.tmpl" | kubectl apply -f -
}

# The existing bucket's spec mirrors what terraform created so neither path
# triggers drift correction; the new bucket's spec is the source of truth ACK
# uses to create it.
apply_bucket_cr "$EXISTING_BUCKET" "terraform-then-ack"
apply_bucket_cr "$NEW_BUCKET"      "ack"

wait_synced() {
  local name=$1
  local timeout=120 elapsed=0 interval=5 status
  echo ">> waiting for $name ACK.ResourceSynced=True (timeout ${timeout}s)"
  while (( elapsed < timeout )); do
    status=$(kubectl get bucket "$name" \
      -o jsonpath='{.status.conditions[?(@.type=="ACK.ResourceSynced")].status}' 2>/dev/null || true)
    if [[ "$status" == "True" ]]; then
      echo "   $name synced after ${elapsed}s"
      return 0
    fi
    echo "   $name ResourceSynced=${status:-<not set yet>} (${elapsed}s)"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  echo "!! timed out waiting for $name to sync" >&2
  echo "!! Bucket CR state:" >&2
  kubectl get bucket "$name" -o yaml >&2 || true
  echo "!! Controller logs:" >&2
  kubectl -n "$NAMESPACE" logs deploy/ack-s3-controller --tail=80 >&2 || true
  return 1
}

wait_synced "$EXISTING_BUCKET"
wait_synced "$NEW_BUCKET"

echo ">> phase 30 complete — adopted: $EXISTING_BUCKET ; created: $NEW_BUCKET"
