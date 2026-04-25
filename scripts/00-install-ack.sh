#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

require_env AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY ACK_CHART_VERSION

echo ">> ensuring namespace $NAMESPACE"
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE"

echo ">> writing credentials secret $SECRET_NAME (AWS shared-credentials format)"
TMP_CREDS=$(mktemp)
trap 'rm -f "$TMP_CREDS"' EXIT
cat > "$TMP_CREDS" <<EOF
[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
EOF
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-file=credentials="$TMP_CREDS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> helm upgrade --install ack-s3-controller (chart version $ACK_CHART_VERSION)"
# NOTE: the chart's value keys for credential wiring have shifted across releases.
# If install warns about unused values, run `helm show values oci://public.ecr.aws/aws-controllers-k8s/s3-chart --version $ACK_CHART_VERSION`
# and adjust the --set keys below.
helm upgrade --install ack-s3-controller \
  oci://public.ecr.aws/aws-controllers-k8s/s3-chart \
  --version "$ACK_CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --set aws.region="$AWS_REGION" \
  --set aws.credentials.secretName="$SECRET_NAME" \
  --set aws.credentials.secretKey="credentials" \
  --set aws.credentials.profile="default" \
  --wait --timeout 3m

echo ">> rollout status"
kubectl -n "$NAMESPACE" rollout status deploy --selector=app.kubernetes.io/name=ack-s3-controller --timeout=2m

echo ">> CRD installed:"
kubectl get crd buckets.s3.services.k8s.aws

echo ">> install complete"
