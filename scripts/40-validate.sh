#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env AWS_REGION

fail() { echo "!! $*" >&2; exit 1; }

[[ -f "$BUCKET_NAME_FILE"     ]] || fail "$BUCKET_NAME_FILE missing — run 10-tf-create.sh first"
[[ -f "$NEW_BUCKET_NAME_FILE" ]] || fail "$NEW_BUCKET_NAME_FILE missing — run 30-adopt.sh first"
[[ -f "$ETAGS_FILE"           ]] || fail "$ETAGS_FILE missing — run 10-tf-create.sh first"

EXISTING_BUCKET=$(cat "$BUCKET_NAME_FILE")
NEW_BUCKET=$(cat "$NEW_BUCKET_NAME_FILE")

assert_bucket_props() {
  local name=$1 expected_managed_by=$2
  aws s3api head-bucket --bucket "$name" --region "$AWS_REGION" \
    || fail "$name head-bucket failed"

  local v
  v=$(aws s3api get-bucket-versioning --bucket "$name" --region "$AWS_REGION" \
        --query 'Status' --output text)
  [[ "$v" == "Enabled" ]] || fail "$name versioning is '$v', expected Enabled"

  local p m
  p=$(aws s3api get-bucket-tagging --bucket "$name" --region "$AWS_REGION" \
        --query 'TagSet[?Key==`Purpose`].Value | [0]' --output text 2>/dev/null || echo "")
  m=$(aws s3api get-bucket-tagging --bucket "$name" --region "$AWS_REGION" \
        --query 'TagSet[?Key==`ManagedBy`].Value | [0]' --output text 2>/dev/null || echo "")
  [[ "$p" == "ack-adoption-demo"   ]] || fail "$name Purpose='$p' (expected ack-adoption-demo)"
  [[ "$m" == "$expected_managed_by" ]] || fail "$name ManagedBy='$m' (expected $expected_managed_by)"
}

assert_ack_synced() {
  local name=$1 synced arn
  synced=$(kubectl get bucket "$name" \
    -o jsonpath='{.status.conditions[?(@.type=="ACK.ResourceSynced")].status}' 2>/dev/null || echo "")
  arn=$(kubectl get bucket "$name" \
    -o jsonpath='{.status.ackResourceMetadata.arn}' 2>/dev/null || echo "")
  [[ "$synced" == "True" ]] || fail "$name ACK.ResourceSynced=$synced (expected True)"
  [[ -n "$arn" ]]            || fail "$name status.ackResourceMetadata.arn empty"
  echo "   ACK CR ok ($arn)"
}

echo ">> ADOPT path  — $EXISTING_BUCKET  (terraform-created, then adopted)"
echo "   [1/4] bucket present in AWS, versioning + tags preserved"
assert_bucket_props "$EXISTING_BUCKET" "terraform-then-ack"
echo "   ok"

echo "   [2/4] seeded objects intact (etag match against phase-10 baseline)"
FAILED=0
while IFS=$'\t' read -r KEY EXPECTED; do
  ACTUAL=$(aws s3api head-object --bucket "$EXISTING_BUCKET" --key "$KEY" --region "$AWS_REGION" \
    --query 'ETag' --output text 2>/dev/null | tr -d '"' || echo "MISSING")
  if [[ "$ACTUAL" == "$EXPECTED" ]]; then
    echo "     $KEY  ok  ($ACTUAL)"
  else
    echo "!!   $KEY  expected=$EXPECTED  actual=$ACTUAL" >&2
    FAILED=1
  fi
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$ETAGS_FILE")
(( FAILED == 0 )) || fail "object integrity check failed"

echo "   [3/4] ACK CR ResourceSynced=True with ARN populated"
assert_ack_synced "$EXISTING_BUCKET"

echo "   [4/4] CR spec.name matches bucket"
SPEC_NAME=$(kubectl get bucket "$EXISTING_BUCKET" -o jsonpath='{.spec.name}')
[[ "$SPEC_NAME" == "$EXISTING_BUCKET" ]] || fail "spec.name='$SPEC_NAME' (expected $EXISTING_BUCKET)"
echo "   ok"

echo ""
echo ">> CREATE path — $NEW_BUCKET  (no prior AWS resource, ACK created from spec)"
echo "   [1/2] bucket present in AWS with versioning + tags from spec"
assert_bucket_props "$NEW_BUCKET" "ack"
echo "   ok"

echo "   [2/2] ACK CR ResourceSynced=True with ARN populated"
assert_ack_synced "$NEW_BUCKET"

echo ""
echo "ALL VALIDATIONS PASSED"
echo "  adopted: $EXISTING_BUCKET"
echo "  created: $NEW_BUCKET"
