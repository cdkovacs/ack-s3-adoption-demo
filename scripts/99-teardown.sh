#!/usr/bin/env bash
# Tolerant teardown — every step must accept "already gone" without aborting later steps.
set -uo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

BUCKET_NAME=""
[[ -f "$BUCKET_NAME_FILE" ]] && BUCKET_NAME=$(cat "$BUCKET_NAME_FILE")

empty_versioned_bucket() {
  local bucket=$1
  while true; do
    local payload count
    payload=$(aws s3api list-object-versions \
      --bucket "$bucket" --region "$AWS_REGION" \
      --max-items 1000 --output json 2>/dev/null \
      | jq '{Objects: ((.Versions // []) + (.DeleteMarkers // []) | map({Key, VersionId}))}' 2>/dev/null) || break
    count=$(echo "$payload" | jq '.Objects | length')
    [[ "$count" == "0" ]] && break
    echo "$payload" | jq '. + {Quiet: true}' > /tmp/ack-demo-delete.json
    aws s3api delete-objects --bucket "$bucket" --region "$AWS_REGION" \
      --delete "file:///tmp/ack-demo-delete.json" >/dev/null || break
  done
  rm -f /tmp/ack-demo-delete.json
}

if [[ -n "$BUCKET_NAME" ]]; then
  if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    echo ">> emptying $BUCKET_NAME"
    empty_versioned_bucket "$BUCKET_NAME"
  fi

  echo ">> deleting Bucket CR (ACK will delete the bucket in AWS)"
  kubectl delete bucket "$BUCKET_NAME" --ignore-not-found --wait=true --timeout=60s 2>/dev/null || true

  # Fallback: if ACK didn't delete (controller missing, CR never existed, etc.)
  if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    echo ">> bucket still in AWS; deleting directly"
    empty_versioned_bucket "$BUCKET_NAME"
    aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null || true
  fi
fi

echo ">> uninstalling ACK controller"
helm uninstall ack-s3-controller -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo ">> deleting namespace $NAMESPACE"
kubectl delete ns "$NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true

echo ">> wiping terraform state and run files"
rm -rf "$DEMO_DIR/terraform/.terraform" \
       "$DEMO_DIR/terraform/.terraform.lock.hcl" \
       "$DEMO_DIR/terraform/terraform.tfstate" \
       "$DEMO_DIR/terraform/terraform.tfstate.backup" \
       "$BUCKET_NAME_FILE" \
       "$ETAGS_FILE"

echo ">> teardown complete"
