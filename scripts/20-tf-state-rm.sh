#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

cd "$DEMO_DIR/terraform"

echo ">> resources currently in state:"
terraform state list || true

mapfile -t RESOURCES < <(terraform state list 2>/dev/null || true)

if [[ ${#RESOURCES[@]} -eq 0 ]]; then
  echo ">> state already empty — nothing to remove"
  exit 0
fi

# Remove every managed resource. The bucket and its objects stay in AWS;
# Terraform just forgets about them. This is the unmanaging step the test exercises.
for r in "${RESOURCES[@]}"; do
  echo ">> terraform state rm '$r'"
  terraform state rm "$r"
done

echo ">> state after removal:"
terraform state list || true

echo ">> phase 20 complete"
