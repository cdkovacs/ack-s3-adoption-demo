# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

A scripted, re-runnable demo that validates the AWS Controllers for Kubernetes (ACK) S3 controller can **adopt** an S3 bucket previously managed by Terraform without losing data or mutating bucket configuration. Target environment is a **local Rancher cluster** — no IRSA available, so the controller is authenticated via a Kubernetes Secret.

## Layout

```
/
├── .env.example                 # AWS_REGION, AWS creds, BUCKET_PREFIX (real .env is gitignored)
├── terraform/                   # bucket + seeded objects; outputs ETags as integrity baseline
├── manifests/
│   └── adopted-bucket.yaml.tmpl # envsubst'd with bucket name at apply time
├── scripts/
│   ├── 00-install-ack.sh
│   ├── 10-tf-create.sh
│   ├── 20-tf-state-rm.sh
│   ├── 30-adopt.sh
│   ├── 40-validate.sh
│   └── 99-teardown.sh
└── demo.sh                      # orchestrates 00→40; supports --reset to teardown first
```

## Commands

- Full demo: `./demo.sh` (pass `--reset` to teardown first)
- Teardown only: `./scripts/99-teardown.sh`
- Re-run one phase: `./scripts/<NN>-*.sh` — each phase is independently idempotent

## Test flow

**Setup (phase `00`)** — `helm upgrade --install` from `oci://public.ecr.aws/aws-controllers-k8s/s3-chart` into `ack-system`. Pin the chart version. Credentials come from Secret `ack-s3-user-creds` referenced via Helm values.

The four test phases:

1. **Terraform create** (`10`) — `aws_s3_bucket` + 2–3 `aws_s3_object` resources with known content. ETags are exported as outputs and persisted; this is the integrity baseline phase 4 compares against.
2. **State removal** (`20`) — `terraform state rm` for the bucket **and every object**. A leftover object in state breaks future plans.
3. **ACK adoption** (`30`) — apply a `Bucket` CR (`s3.services.k8s.aws/v1alpha1`) with annotation `services.k8s.aws/adoption-policy: adopt` and `spec.name` matching the bucket. Poll `status.conditions[type=ACK.ResourceSynced]` until `True`.
4. **Validate** (`40`) — `head-object` ETags match the phase-1 outputs; the `Bucket` CR shows `ACK.ResourceSynced=True` with a populated `status.ackResourceMetadata.arn`.

## Conventions

- **Idempotency** — every script is safely re-runnable. Use `helm upgrade --install`, `kubectl apply`, `--ignore-not-found` on deletes, and tolerate `terraform state rm` no-ops when a resource is already absent.
- **Bucket naming** — `${BUCKET_PREFIX}-$(date +%s)` per run, written to `demo/.run-bucket-name` so later phases read the same value. A fresh suffix per run avoids global-namespace collisions when a prior teardown failed.
- **Credentials** — never commit AWS keys. `.env` is gitignored; the install script reads it and writes the Secret. Scope the IAM user to S3 actions on the test bucket ARN — don't reuse a power-user key.
- **Version pinning** — pin the ACK chart version explicitly. The chart's credential value keys have shifted across releases; check `helm show values <chart> --version <X>` when bumping.

## Teardown order

1. `aws s3 rm s3://$BUCKET --recursive` — ACK refuses to delete a non-empty bucket.
2. `kubectl delete bucket $BUCKET --ignore-not-found` — ACK then deletes the bucket in AWS.
3. Wait for the CR to disappear, then `helm uninstall` the controller and delete the namespace.
4. Wipe Terraform state and `demo/.run-bucket-name`.

## Potential failure modes

- A `Bucket` CR stuck at `ACK.ResourceSynced=Unknown` is almost always a credentials problem, not an adoption bug. Check `kubectl -n ack-system logs deploy/ack-s3-controller` for `NoCredentialProviders` before debugging the CR.
- Validation false-positive risk: if phase 1 only sets default bucket properties, phase 4 only proves "data wasn't deleted." Set non-default properties (versioning, tags, lifecycle) in phase 1 and assert they survive — that's what catches a controller that mutates configuration on adopt.
