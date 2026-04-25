#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY BUCKET_PREFIX

if [[ -f "$BUCKET_NAME_FILE" ]]; then
  BUCKET_NAME=$(cat "$BUCKET_NAME_FILE")
  echo ">> reusing bucket name from prior run: $BUCKET_NAME"
else
  BUCKET_NAME="${BUCKET_PREFIX}-$(date +%s)"
  echo "$BUCKET_NAME" > "$BUCKET_NAME_FILE"
  echo ">> generated bucket name: $BUCKET_NAME"
fi

cd "$DEMO_DIR/terraform"

echo ">> terraform init"
terraform init -input=false -upgrade=false

echo ">> terraform apply"
terraform apply -input=false -auto-approve \
  -var "region=$AWS_REGION" \
  -var "bucket_name=$BUCKET_NAME"

echo ">> capturing etag baseline -> $ETAGS_FILE"
terraform output -json etags > "$ETAGS_FILE"
cat "$ETAGS_FILE"
echo

echo ">> phase 10 complete"
