# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

A scripted, re-runnable demo that exercises the ACK S3 controller's `adopt-or-create` adoption policy on **both branches** in a single run:

- **adopt branch** — an S3 bucket previously created and seeded by Terraform, then `terraform state rm`'d, is adopted by ACK without data loss or config mutation.
- **create branch** — a second `Bucket` CR with the same `adopt-or-create` annotation but no matching AWS bucket: ACK creates it from spec.

Target environment is a **local Rancher cluster** — no IRSA available, so the controller is authenticated via a Kubernetes Secret.

## Layout

```
/
├── .env.example                 # AWS_REGION, AWS creds, BUCKET_PREFIX (real .env is gitignored)
├── terraform/                   # bucket + seeded objects; outputs ETags as integrity baseline
├── manifests/
│   └── adopted-bucket.yaml.tmpl # envsubst'd with BUCKET_NAME + MANAGED_BY; rendered twice in phase 30
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

1. **Terraform create** (`10`) — `aws_s3_bucket` + 2–3 `aws_s3_object` resources with known content; versioning Enabled and `Purpose`/`ManagedBy` tags set. ETags are exported as outputs and persisted; this is the integrity baseline phase 4 compares against.
2. **State removal** (`20`) — `terraform state rm` for the bucket **and every object**. A leftover object in state breaks future plans.
3. **ACK adopt-or-create** (`30`) — generates a *second* bucket name (no AWS resource yet), then applies **two** `Bucket` CRs (`s3.services.k8s.aws/v1alpha1`) both with annotation `services.k8s.aws/adoption-policy: adopt-or-create`. Spec carries `versioning` and `tagging` (matching terraform's values for the existing bucket so adoption sees no drift; defining the desired state for the new one). Poll `status.conditions[type=ACK.ResourceSynced]=True` for both.
4. **Validate** (`40`) — for the existing bucket: ETags match phase-1 baseline, versioning still Enabled, `ManagedBy=terraform-then-ack` survived, CR synced + ARN populated. For the new bucket: bucket exists in AWS, versioning Enabled, `ManagedBy=ack`, CR synced + ARN populated.

## Conventions

- **Idempotency** — every script is safely re-runnable. Use `helm upgrade --install`, `kubectl apply`, `--ignore-not-found` on deletes, and tolerate `terraform state rm` no-ops when a resource is already absent.
- **Bucket naming** — `${BUCKET_PREFIX}-$(date +%s)` for the terraform bucket (written to `.run-bucket-name` in phase 10), and `${BUCKET_PREFIX}-new-$(date +%s)` for the ACK-created bucket (written to `.run-new-bucket-name` in phase 30). Both files are read by later phases so re-running individual phases is safe. Fresh suffixes per run avoid global-namespace collisions when a prior teardown failed.
- **Credentials** — never commit AWS keys. `.env` is gitignored; the install script reads it and writes the Secret. Scope the IAM user to S3 actions on the test bucket ARN — don't reuse a power-user key.
- **Version pinning** — pin the ACK chart version explicitly. The chart's credential value keys have shifted across releases; check `helm show values <chart> --version <X>` when bumping.

## Teardown order

For *each* of the two buckets (terraform-adopted and ACK-created):

1. Empty all object versions + delete markers — ACK refuses to delete a non-empty versioned bucket.
2. `kubectl delete bucket $BUCKET --ignore-not-found` — ACK then deletes the bucket in AWS.
3. Fallback: if the bucket is still in AWS afterwards (controller missing, CR never created, etc.), delete directly via `s3api`.

Then `helm uninstall` the controller, delete the namespace, and wipe Terraform state plus both `.run-*bucket-name` files and `.run-etags.json`.

## Potential failure modes

- A `Bucket` CR stuck at `ACK.ResourceSynced=Unknown` is almost always a credentials problem, not an adoption bug. Check `kubectl -n ack-system logs deploy/ack-s3-controller` for `NoCredentialProviders` before debugging the CR.
- Validation false-positive risk: if phase 1 only sets default bucket properties, phase 4 only proves "data wasn't deleted." Set non-default properties (versioning, tags, lifecycle) in phase 1 and assert they survive — that's what catches a controller that mutates configuration on adopt.
- Drift correction on adopt: with `adopt-or-create`, the controller reconciles spec against actual state. If the spec under-specifies (e.g. omits a tag terraform set), ACK will *remove* that tag to match spec. The existing-bucket CR's spec must mirror the terraform-set values exactly, or the "adoption preserves config" assertion fails — not because adoption is broken but because the spec asked for something different.
- `adopt-or-create` requires ACK runtime ≥ v0.30.0. Older charts only understand `adopt`; the annotation is silently ignored and the controller will refuse to adopt with no helpful condition. Confirm the chart bundles a runtime that supports it before bumping the chart pin.
