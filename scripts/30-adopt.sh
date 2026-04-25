#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

if [[ ! -f "$BUCKET_NAME_FILE" ]]; then
  echo "!! $BUCKET_NAME_FILE missing — run 10-tf-create.sh first" >&2
  exit 1
fi
BUCKET_NAME=$(cat "$BUCKET_NAME_FILE")
export BUCKET_NAME

echo ">> applying ACK Bucket CR for $BUCKET_NAME"
envsubst < "$DEMO_DIR/manifests/adopted-bucket.yaml.tmpl" | kubectl apply -f -

echo ">> waiting for ACK.ResourceSynced=True (timeout 2m)"
TIMEOUT=120
ELAPSED=0
INTERVAL=5
while (( ELAPSED < TIMEOUT )); do
  STATUS=$(kubectl get bucket "$BUCKET_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="ACK.ResourceSynced")].status}' 2>/dev/null || true)
  if [[ "$STATUS" == "True" ]]; then
    echo ">> adopted (synced after ${ELAPSED}s)"
    exit 0
  fi
  echo "   ResourceSynced=${STATUS:-<not set yet>} (${ELAPSED}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "!! timed out waiting for adoption" >&2
echo "!! Bucket CR state:" >&2
kubectl get bucket "$BUCKET_NAME" -o yaml >&2 || true
echo "!! Controller logs:" >&2
kubectl -n "$NAMESPACE" logs deploy/ack-s3-controller --tail=50 >&2 || true
exit 1
