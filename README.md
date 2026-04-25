# ACK S3 Adoption Demo

A scripted, re-runnable test that proves the [AWS Controllers for Kubernetes](https://aws-controllers-k8s.github.io/community/) (ACK) S3 controller can **adopt** an S3 bucket previously managed by Terraform without losing data or mutating bucket configuration.

![demo gif](demo.gif)

## What it does

1. Installs the ACK S3 controller into a local Rancher cluster (Helm).
2. Uses Terraform to create an S3 bucket with versioning, a tag, and three seeded objects.
3. Runs `terraform state rm` so Terraform forgets the bucket (without deleting it in AWS).
4. Applies a `Bucket` custom resource with the `services.k8s.aws/adoption-policy: adopt` annotation so the ACK controller adopts the existing bucket.
5. Validates that the bucket still exists, versioning is still on, the tag is unchanged, every seeded object's ETag matches the pre-adoption baseline, and the CR reports `ACK.ResourceSynced=True` with an ARN populated.

A clean teardown script removes everything in the right order (empty bucket → delete CR → uninstall controller → wipe Terraform state) and tolerates partial state from a failed prior run.

## Prerequisites

- A local Rancher / RKE2 / K3s cluster with `kubectl` configured to point at it.
- `helm` 3.8+ (OCI registry support).
- `terraform` >= 1.5.
- `aws` CLI v2, `jq`, `envsubst` (`gettext` package).
- A dedicated IAM user for the demo (see next section) — don't reuse a power-user key.

## AWS IAM setup

Create a dedicated IAM user with a policy scoped to buckets matching your `BUCKET_PREFIX`. The commands below assume the default `BUCKET_PREFIX=ack-adopt-demo` from `.env.example` — change the resource ARNs if you pick a different prefix.

These commands need an existing AWS identity with IAM permissions (admin, or someone who can `iam:CreateUser`, `iam:PutUserPolicy`, `iam:CreateAccessKey`). If you don't have IAM access, hand the policy below to whoever does.

### 1. Save the policy file

`ack-demo-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DemoBucketOps",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::ack-adopt-demo-*",
        "arn:aws:s3:::ack-adopt-demo-*/*"
      ]
    },
    {
      "Sid": "ListAllBuckets",
      "Effect": "Allow",
      "Action": "s3:ListAllMyBuckets",
      "Resource": "*"
    }
  ]
}
```

Why this scope: `s3:*` looks broad, but the first statement is **resource-scoped** to bucket names matching `ack-adopt-demo-*` — the user cannot touch any other bucket in the account. Action-level wildcards are used because Terraform's S3 provider calls many `GetBucket*` sub-resources during refresh; enumerating them is brittle and gains nothing once the resource scope is tight.

The second statement (`s3:ListAllMyBuckets`) is an account-level action that AWS does not allow to be resource-scoped — it must be granted on `*`. The ACK S3 controller calls it during reconciliation. It only reveals bucket names in the account, not their contents.

### 2. Create the user, attach the policy, mint an access key

```bash
aws iam create-user --user-name ack-adopt-demo

aws iam put-user-policy \
  --user-name ack-adopt-demo \
  --policy-name ack-adopt-demo \
  --policy-document file://ack-demo-policy.json

aws iam create-access-key --user-name ack-adopt-demo
```

The last command prints `AccessKey.AccessKeyId` and `AccessKey.SecretAccessKey` — copy these into `demo/.env` as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. The secret is shown **only once**; if you lose it, delete the key and create a new one.

### 3. Clean up the IAM user (after you're done with the demo)

```bash
# Get the access key id if you don't have it handy
aws iam list-access-keys --user-name ack-adopt-demo

aws iam delete-access-key --user-name ack-adopt-demo --access-key-id AKIA...
aws iam delete-user-policy --user-name ack-adopt-demo --policy-name ack-adopt-demo
aws iam delete-user --user-name ack-adopt-demo
```

## Setup

```bash
cp demo/.env.example demo/.env
# edit demo/.env: AWS creds, AWS_REGION, BUCKET_PREFIX, ACK_CHART_VERSION
```

Find a current chart version with:

```bash
helm show chart oci://public.ecr.aws/aws-controllers-k8s/s3-chart
```

Pin it in `demo/.env` — `latest` is not reproducible and the chart's credential value keys have shifted between minor versions.

## Run

```bash
./demo/demo.sh             # full demo
./demo/demo.sh --reset     # teardown first, then run
```

Each phase is also runnable on its own and is idempotent:

```bash
./demo/scripts/00-install-ack.sh
./demo/scripts/10-tf-create.sh
./demo/scripts/20-tf-state-rm.sh
./demo/scripts/30-adopt.sh
./demo/scripts/40-validate.sh
./demo/scripts/99-teardown.sh
```

## Layout

```
demo/
├── .env.example                 # template for .env (gitignored)
├── terraform/                   # bucket + seeded objects, ETags exported
├── manifests/
│   └── adopted-bucket.yaml.tmpl # Bucket CR with the adopt annotation
├── scripts/
│   ├── _lib.sh                  # shared env loading + helpers
│   ├── 00-install-ack.sh        # helm install + credentials Secret
│   ├── 10-tf-create.sh          # terraform apply, dump ETag baseline
│   ├── 20-tf-state-rm.sh        # remove every resource from state
│   ├── 30-adopt.sh              # apply CR, poll ACK.ResourceSynced
│   ├── 40-validate.sh           # 5 checks; non-zero exit on any failure
│   └── 99-teardown.sh           # tolerant cleanup
└── demo.sh                      # orchestrator
```

## Troubleshooting

- **`Bucket` CR stuck at `ACK.ResourceSynced=Unknown`** — almost always a credentials problem, not an adoption bug. Check the controller logs first:
  ```
  kubectl -n ack-system logs deploy/ack-s3-controller
  ```
  Look for `NoCredentialProviders` or auth errors.
- **Helm install warns "values not used"** — the chart's credential value keys vary by version. Run `helm show values oci://public.ecr.aws/aws-controllers-k8s/s3-chart --version <X>` and update the `--set` flags in `00-install-ack.sh`.
- **Bucket name collision** — fresh suffix per run normally avoids this. If a prior teardown left a bucket behind, run `./demo/scripts/99-teardown.sh` (it tolerates "already gone").
- **Validation failed on versioning/tag** — this is the failure mode the test was built to catch: the controller mutated bucket config on adopt rather than just importing it. Capture the controller version and file an issue with the project.
