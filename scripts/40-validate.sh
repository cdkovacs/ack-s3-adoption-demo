#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env AWS_REGION

if [[ ! -f "$BUCKET_NAME_FILE" ]]; then
  echo "!! $BUCKET_NAME_FILE missing — run 10-tf-create.sh first" >&2
  exit 1
fi
BUCKET_NAME=$(cat "$BUCKET_NAME_FILE")

if [[ ! -f "$ETAGS_FILE" ]]; then
  echo "!! baseline etags missing at $ETAGS_FILE — run 10-tf-create.sh first" >&2
  exit 1
fi

fail() { echo "!! $*" >&2; exit 1; }

echo ">> [1/5] bucket exists in AWS"
aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
  || fail "head-bucket failed"
echo "   ok"

echo ">> [2/5] versioning still Enabled"
VERSIONING=$(aws s3api get-bucket-versioning --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
  --query 'Status' --output text)
[[ "$VERSIONING" == "Enabled" ]] || fail "versioning is '$VERSIONING', expected Enabled (controller mutated config?)"
echo "   ok"

echo ">> [3/5] Purpose tag still present"
TAG_VALUE=$(aws s3api get-bucket-tagging --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
  --query 'TagSet[?Key==`Purpose`].Value | [0]' --output text 2>/dev/null || echo "")
[[ "$TAG_VALUE" == "ack-adoption-demo" ]] || fail "Purpose tag missing or wrong: '$TAG_VALUE'"
echo "   ok"

echo ">> [4/5] seeded objects intact (etag match)"
FAILED=0
while IFS=$'\t' read -r KEY EXPECTED; do
  ACTUAL=$(aws s3api head-object --bucket "$BUCKET_NAME" --key "$KEY" --region "$AWS_REGION" \
    --query 'ETag' --output text 2>/dev/null | tr -d '"' || echo "MISSING")
  if [[ "$ACTUAL" == "$EXPECTED" ]]; then
    echo "   $KEY  ok  ($ACTUAL)"
  else
    echo "!! $KEY  expected=$EXPECTED  actual=$ACTUAL" >&2
    FAILED=1
  fi
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$ETAGS_FILE")
(( FAILED == 0 )) || fail "object integrity check failed"

echo ">> [5/5] ACK CR shows ResourceSynced=True with ARN populated"
SYNCED=$(kubectl get bucket "$BUCKET_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="ACK.ResourceSynced")].status}' 2>/dev/null || echo "")
ARN=$(kubectl get bucket "$BUCKET_NAME" \
  -o jsonpath='{.status.ackResourceMetadata.arn}' 2>/dev/null || echo "")
[[ "$SYNCED" == "True" ]] || fail "ACK.ResourceSynced=$SYNCED (expected True)"
[[ -n "$ARN" ]]           || fail "status.ackResourceMetadata.arn is empty"
echo "   ok ($ARN)"

echo ""
echo "ALL VALIDATIONS PASSED for $BUCKET_NAME"
